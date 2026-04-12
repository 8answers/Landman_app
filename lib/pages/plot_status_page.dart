import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:universal_html/html.dart' as html;
import 'package:url_launcher/url_launcher.dart';
import 'dart:ui';
import '../widgets/decimal_input_field.dart';
import '../services/layout_storage_service.dart';
import '../services/offline_file_upload_queue_service.dart';
import '../services/offline_project_sync_service.dart';
import '../services/project_storage_service.dart';
import '../services/area_unit_service.dart';
import '../utils/area_unit_utils.dart';
import '../utils/download_file.dart';
import '../utils/local_file_picker.dart';
import '../utils/web_print.dart';
import '../utils/web_arrow_key_scroll_binding.dart';
import '../widgets/area_unit_selector.dart';
import '../widgets/app_scale_metrics.dart';
import '../widgets/header_refresh_button.dart';
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

enum _LayoutViewerCloseDecision {
  save,
  discard,
}

class PlotStatusPage extends StatefulWidget {
  final List<Map<String, dynamic>>? layouts;
  final List<Map<String, dynamic>>? agents;
  final String? projectId;
  final int dataVersion;
  final bool isActive;
  final bool isNetworkReachable;
  final Function(bool)? onPlotStatusErrorsChanged;
  final ValueChanged<bool>? onLoadingStateChanged;
  final ValueChanged<bool>? onEditDialogVisibilityChanged;
  final Function(ProjectSaveStatusType)? onSaveStatusChanged;
  final VoidCallback? onNavigateToDataEntrySite;

  const PlotStatusPage({
    super.key,
    this.layouts,
    this.agents,
    this.projectId,
    this.dataVersion = 0,
    this.isActive = true,
    this.isNetworkReachable = true,
    this.onPlotStatusErrorsChanged,
    this.onLoadingStateChanged,
    this.onEditDialogVisibilityChanged,
    this.onSaveStatusChanged,
    this.onNavigateToDataEntrySite,
  });

  @override
  State<PlotStatusPage> createState() => _PlotStatusPageState();
}

class _PlotStatusSessionSnapshot {
  final List<Map<String, dynamic>> layouts;
  final List<Map<String, dynamic>> amenityAreas;
  final List<Map<String, dynamic>> agents;
  final String amenityLayoutImageName;
  final String amenityLayoutImagePath;
  final String amenityLayoutImageDocId;
  final String amenityLayoutImageExtension;

  const _PlotStatusSessionSnapshot({
    required this.layouts,
    required this.amenityAreas,
    required this.agents,
    required this.amenityLayoutImageName,
    required this.amenityLayoutImagePath,
    required this.amenityLayoutImageDocId,
    required this.amenityLayoutImageExtension,
  });
}

class _PlotStatusPageState extends State<PlotStatusPage> {
  static final Map<String, _PlotStatusSessionSnapshot>
      _sessionSnapshotByProject = <String, _PlotStatusSessionSnapshot>{};
  static final Map<String, Future<void>> _inFlightLoadByProject =
      <String, Future<void>>{};
  static const Color _scrollbarThumbBaseColor = Color(0x7A4E4E4E);
  static const Color _scrollbarThumbActiveColor = Color(0xFF3F3F3F);

  void _notifyLoadingState(bool isLoading) {
    widget.onLoadingStateChanged?.call(isLoading);
  }

  void _notifyEditDialogVisibilityChanged(bool isVisible) {
    widget.onEditDialogVisibilityChanged?.call(isVisible);
  }

  final SupabaseClient _supabase = Supabase.instance.client;
  final ScrollController _scrollController = ScrollController();
  late final WebArrowKeyScrollBinding _arrowKeyScrollBinding =
      WebArrowKeyScrollBinding(controller: _scrollController);
  final GlobalKey _contentViewportKey = GlobalKey();
  final GlobalKey _layoutsToolbarAnchorKey = GlobalKey();
  bool _showStickyLayoutsToolbar = false;
  bool _stickyToolbarEvaluationScheduled = false;
  static const double _layoutsToolbarAnchorHeight = 36.0;
  String _selectedLayout = 'All Layouts';
  String _selectedStatus = 'All Status';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // Loading state
  bool _isLoading = true;
  bool _hasUnsavedChanges = false;
  bool _isAutoRetryInProgress = false;
  bool _isLayoutSaveInFlight = false;
  bool _hasQueuedLayoutSave = false;
  Timer? _layoutSaveDebounceTimer;
  Completer<void>? _queuedLayoutSaveCompleter;
  int _emptyPlotsLoadRetryCount = 0;
  int _plotDataLoadGeneration = 0;
  bool _reloadWhenActivated = false;
  String _lastLoadedProjectId = '';
  bool _hasLoadedCurrentProjectOnce = false;
  bool _isLoadInProgress = false;
  bool _forceShowFullPageLoadingSkeleton = false;
  bool _projectAmenityMetaColumnsMissing = false;
  bool _invalidEditDialogResetScheduled = false;
  StreamSubscription<html.Event>? _onlineSubscription;
  static const Duration _layoutSaveDebounceDelay = Duration(milliseconds: 350);
  static const Duration _forcedRefreshSkeletonMin = Duration(milliseconds: 320);
  final Map<String, String> _lastSyncedLayoutSignatures = <String, String>{};
  final Map<String, String> _lastSyncedPlotSignatures = <String, String>{};

  dynamic _deepCloneValue(dynamic value) {
    if (value is Map) {
      return value.map(
        (key, nested) => MapEntry(key.toString(), _deepCloneValue(nested)),
      );
    }
    if (value is List) {
      return value.map(_deepCloneValue).toList(growable: false);
    }
    return value;
  }

  List<Map<String, dynamic>> _cloneMapList(
    List<Map<String, dynamic>> source,
  ) {
    return source
        .map(
          (row) => row.map(
            (key, value) => MapEntry(key, _deepCloneValue(value)),
          ),
        )
        .toList(growable: false);
  }

  Map<String, dynamic> _coerceMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map(
        (key, nestedValue) => MapEntry(key.toString(), nestedValue),
      );
    }
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _coerceMapList(dynamic value) {
    if (value is! List) return const <Map<String, dynamic>>[];
    return value.map((row) => _coerceMap(row)).toList(growable: false);
  }

  bool _layoutCollectionsRoughlyEqual(
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> snapshot,
  ) {
    if (identical(current, snapshot)) return true;
    if (current.length != snapshot.length) return false;

    for (var i = 0; i < current.length; i++) {
      final currentLayout = _coerceMap(current[i]);
      final snapshotLayout = _coerceMap(snapshot[i]);

      if ((currentLayout['id'] ?? '').toString().trim() !=
              (snapshotLayout['id'] ?? '').toString().trim() ||
          (currentLayout['name'] ?? '').toString().trim() !=
              (snapshotLayout['name'] ?? '').toString().trim()) {
        return false;
      }

      final currentPlots = _coerceMapList(currentLayout['plots']);
      final snapshotPlots = _coerceMapList(snapshotLayout['plots']);
      if (currentPlots.length != snapshotPlots.length) return false;

      for (var j = 0; j < currentPlots.length; j++) {
        final currentPlot = _coerceMap(currentPlots[j]);
        final snapshotPlot = _coerceMap(snapshotPlots[j]);
        final currentStatus = _parsePlotStatus(currentPlot['status']);
        final snapshotStatus = _parsePlotStatus(snapshotPlot['status']);

        if ((currentPlot['id'] ?? '').toString().trim() !=
                (snapshotPlot['id'] ?? '').toString().trim() ||
            (currentPlot['plotNumber'] ?? '').toString().trim() !=
                (snapshotPlot['plotNumber'] ?? '').toString().trim() ||
            currentStatus != snapshotStatus) {
          return false;
        }
      }
    }

    return true;
  }

  void _cacheCurrentStateForSession(String projectId) {
    if (projectId.isEmpty) return;
    _sessionSnapshotByProject[projectId] = _PlotStatusSessionSnapshot(
      layouts: _cloneMapList(_layouts),
      amenityAreas: _cloneMapList(_amenityAreas),
      agents: _cloneMapList(_storedAgents),
      amenityLayoutImageName: _amenityLayoutImageName,
      amenityLayoutImagePath: _amenityLayoutImagePath,
      amenityLayoutImageDocId: _amenityLayoutImageDocId,
      amenityLayoutImageExtension: _amenityLayoutImageExtension,
    );
  }

  bool _restoreSessionSnapshot(String projectId, {bool silently = false}) {
    if (projectId.isEmpty) return false;
    final snapshot = _sessionSnapshotByProject[projectId];
    if (snapshot == null) return false;
    // Prevent redundant full rebuild/controller re-init when this exact
    // project is already considered loaded in this widget state.
    // Important: treat empty-data projects as loaded too.
    if (_lastLoadedProjectId == projectId && _hasLoadedCurrentProjectOnce) {
      return true;
    }

    // Fallback guard for legacy in-memory checks.
    if (_lastLoadedProjectId == projectId &&
        _hasLoadedCurrentProjectOnce &&
        _layouts.isNotEmpty &&
        _allPlots.isNotEmpty) {
      return true;
    }

    // If the current in-memory layouts already match the snapshot, avoid a
    // full rebuild/controller re-init cycle.
    if (_layoutCollectionsRoughlyEqual(_layouts, snapshot.layouts)) {
      _lastLoadedProjectId = projectId;
      _hasLoadedCurrentProjectOnce = true;
      _isLoading = false;
      _notifyLoadingState(false);
      return true;
    }

    void applySnapshot() {
      _storedAgents = _cloneMapList(snapshot.agents);
      _layouts = _cloneMapList(snapshot.layouts);
      _amenityAreas = _cloneMapList(snapshot.amenityAreas);
      _amenityLayoutImageName = snapshot.amenityLayoutImageName;
      _amenityLayoutImagePath = snapshot.amenityLayoutImagePath;
      _amenityLayoutImageDocId = snapshot.amenityLayoutImageDocId;
      _amenityLayoutImageExtension = snapshot.amenityLayoutImageExtension;
      _rebuildAllPlotsFromLayouts(
        reason: silently ? 'session_snapshot_silent' : 'session_snapshot',
      );
      _isLoading = false;
    }

    if (mounted) {
      setState(applySnapshot);
    } else {
      applySnapshot();
    }

    _lastLoadedProjectId = projectId;
    _hasLoadedCurrentProjectOnce = true;
    _notifyLoadingState(false);
    if (!silently) {
      _notifyErrorState();
      _initializeControllersFromData();
    }
    return true;
  }

  void _resetPlotStatusViewForProjectChange({required bool showLoading}) {
    _closeCurrentEditDialog();
    _selectedLayout = 'All Layouts';
    _selectedStatus = 'All Status';
    _searchQuery = '';
    _searchController.clear();
    _layouts = <Map<String, dynamic>>[];
    _amenityAreas = <Map<String, dynamic>>[];
    _storedAgents = <Map<String, dynamic>>[];
    _allPlots = <Map<String, dynamic>>[];
    _isLoading = showLoading;
    _forceShowFullPageLoadingSkeleton = showLoading;
  }

  bool _clearInvalidAssignedAgentsFromLayouts({bool rebuildAllPlots = true}) {
    final validAgents = _availableAgents
        .map((agent) => agent.trim().toLowerCase())
        .where((agent) => agent.isNotEmpty)
        .toSet();
    if (validAgents.isEmpty) return false;

    var changed = false;
    for (final layout in _layouts) {
      final plots = _coerceMapList(layout['plots']);
      for (final plot in plots) {
        final currentAgent = (plot['agent'] ?? '').toString().trim();
        final normalizedAgent = currentAgent.toLowerCase();
        if (currentAgent.isEmpty ||
            normalizedAgent == 'direct sale' ||
            validAgents.contains(normalizedAgent)) {
          continue;
        }
        plot['agent'] = '';
        if (plot.containsKey('agentName')) {
          plot['agentName'] = '';
        }
        if (plot.containsKey('agent_name')) {
          plot['agent_name'] = '';
        }
        changed = true;
      }
    }

    if (changed && rebuildAllPlots) {
      _rebuildAllPlotsFromLayouts(reason: 'invalid_agent_cleanup');
      _isAgentDropdownOpen = false;
    }
    return changed;
  }

  String _sanitizeAssignedAgentName(String rawAgent) {
    final agent = rawAgent.trim();
    if (agent.isEmpty) return '';
    if (agent.toLowerCase() == 'direct sale') return agent;
    final validAgents = _availableAgents
        .map((entry) => entry.trim().toLowerCase())
        .where((entry) => entry.isNotEmpty)
        .toSet();
    return validAgents.contains(agent.toLowerCase()) ? agent : '';
  }

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
  final Map<String, int> _buyerNameFieldEpoch = {};

  // Stored agents list from storage
  List<Map<String, dynamic>> _storedAgents = [];
  final Set<int> _layoutImageUploadInProgress = <int>{};
  bool _isAmenityLayoutImageUploadInProgress = false;
  String _amenityLayoutImagePath = '';
  String _amenityLayoutImageDocId = '';
  String _amenityLayoutImageName = '';
  String _amenityLayoutImageExtension = '';

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
  Map<String, dynamic>? _editDialogOriginalPlotSnapshot;
  int? _editDialogOriginalLayoutIndex;
  int? _editDialogOriginalPlotIndex;

  // Layout expand/collapse and zoom state
  Set<int> _collapsedLayouts = {}; // Set of collapsed layout indices
  bool _isAmenityAreaCollapsed = false;
  PlotStatusContentTab _activeContentTab = PlotStatusContentTab.site;
  static const String _globalPlotStatusTabPrefKey =
      'nav_plot_status_active_tab';
  double _tableZoomLevel =
      1.0; // Table zoom level (1.0 = 100%, 0.5 = 50%, 1.2 = 120%, etc.)
  final Set<String> _layoutControlFlashKeys = <String>{};
  final Map<String, Timer> _layoutControlFlashTimers = <String, Timer>{};
  final Set<String> _layoutPressedZoomKeys = <String>{};
  String _areaUnit = AreaUnitService.defaultUnit;
  bool get _isSqm => AreaUnitUtils.isSqm(_areaUnit);
  String get _areaUnitSuffix => AreaUnitUtils.unitSuffix(_isSqm);
  String? _plotsBuyerContactColumnName;
  bool _plotsBuyerContactColumnChecked = false;
  String? _amenityBuyerContactColumnName;
  bool _amenityBuyerContactColumnChecked = false;
  static const String _layoutDocumentsFolderName = 'Layouts';
  static const String _amenityDocumentsFolderName = 'Amenity Area';
  static const String _pendingAmenitySyncQueueKeyPrefix =
      'project_plot_status_pending_amenity_sync_v1_';
  static const String _amenitySnapshotKeyPrefix =
      'project_plot_status_amenity_snapshot_v1_';
  // Dedicated key that stores ONLY amenity status overrides.
  // Keys are amenity row IDs when available, otherwise normalized name keys.
  // Written on every user edit, never cleared by DB loads.
  static const String _amenityStatusOverrideKeyPrefix =
      'project_amenity_status_override_v1_';

  String _plotStatusTabPrefKeyForProject(String? projectId) {
    final normalizedProjectId = (projectId ?? '').trim();
    if (normalizedProjectId.isEmpty) {
      return 'project_plot_status_active_tab_draft';
    }
    return 'project_${normalizedProjectId}_plot_status_active_tab';
  }

  PlotStatusContentTab? _parsePlotStatusTabName(String? value) {
    final normalized = (value ?? '').trim();
    if (normalized.isEmpty) return null;
    for (final tab in PlotStatusContentTab.values) {
      if (tab.name == normalized) return tab;
    }
    return null;
  }

  Future<void> _persistActiveContentTab(PlotStatusContentTab tab) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_globalPlotStatusTabPrefKey, tab.name);
      await prefs.setString(
        _plotStatusTabPrefKeyForProject(widget.projectId),
        tab.name,
      );
    } catch (_) {
      // Best-effort persistence only.
    }
  }

  Future<void> _restoreActiveContentTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final projectScoped =
          prefs.getString(_plotStatusTabPrefKeyForProject(widget.projectId));
      final global = prefs.getString(_globalPlotStatusTabPrefKey);
      final restored = _parsePlotStatusTabName(projectScoped) ??
          _parsePlotStatusTabName(global);
      if (restored == null || !mounted) return;
      if (_activeContentTab != restored) {
        setState(() {
          _activeContentTab = restored;
        });
      }
    } catch (_) {
      // Ignore restore failures and keep current tab.
    }
  }

  void _setActiveContentTab(
    PlotStatusContentTab tab, {
    bool persist = true,
  }) {
    final tabChanged = _activeContentTab != tab;
    if (_activeContentTab != tab) {
      if (mounted) {
        setState(() {
          _activeContentTab = tab;
        });
      } else {
        _activeContentTab = tab;
      }
    }
    if (tabChanged) {
      _scheduleLayoutsStickyStateUpdate();
    }
    if (persist) {
      unawaited(_persistActiveContentTab(tab));
    }
  }

  String _pendingAmenitySyncQueueKeyForProject(String projectId) {
    return '$_pendingAmenitySyncQueueKeyPrefix$projectId';
  }

  String _amenitySnapshotKeyForProject(String projectId) {
    return '$_amenitySnapshotKeyPrefix$projectId';
  }

  String _amenityStatusOverrideKeyForProject(String projectId) {
    return '$_amenityStatusOverrideKeyPrefix$projectId';
  }

  String _amenityStatusOverrideNameKey(dynamic name) {
    final normalized = (name ?? '').toString().trim().toLowerCase();
    if (normalized.isEmpty) return '';
    return 'name:$normalized';
  }

  /// Saves a map of {amenityKey → statusString} to SharedPreferences.
  /// Called every time the user changes an amenity status.
  Future<void> _saveAmenityStatusOverride({
    required String projectId,
    required String amenityId,
    String amenityName = '',
    required String status,
  }) async {
    final pid = projectId.trim();
    final aid = amenityId.trim();
    final nameKey = _amenityStatusOverrideNameKey(amenityName);
    if (pid.isEmpty || (aid.isEmpty && nameKey.isEmpty)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _amenityStatusOverrideKeyForProject(pid);
      final raw = prefs.getString(key);
      final overrides = <String, String>{};
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((k, v) {
              overrides[k.toString()] = v.toString();
            });
          }
        } catch (_) {}
      }
      if (status == 'available') {
        if (aid.isNotEmpty) {
          overrides.remove(aid);
        }
        if (nameKey.isNotEmpty) {
          overrides.remove(nameKey);
        }
      } else if (aid.isNotEmpty) {
        overrides[aid] = status;
        if (nameKey.isNotEmpty) {
          // Prefer id-based override if both are known.
          overrides.remove(nameKey);
        }
      } else if (nameKey.isNotEmpty) {
        overrides[nameKey] = status;
      }
      if (overrides.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, jsonEncode(overrides));
      }
    } catch (_) {}
  }

  /// Loads the {amenityKey → statusString} override map from SharedPreferences.
  Future<Map<String, String>> _loadAmenityStatusOverrides({
    required String projectId,
  }) async {
    final pid = projectId.trim();
    if (pid.isEmpty) return {};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_amenityStatusOverrideKeyForProject(pid));
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, String>{};
      decoded.forEach((k, v) {
        result[k.toString()] = v.toString();
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  /// Applies status overrides to a list of amenity rows (raw DB or snapshot format).
  List<Map<String, dynamic>> _applyAmenityStatusOverrides(
    List<Map<String, dynamic>> rows,
    Map<String, String> overrides,
  ) {
    if (overrides.isEmpty) return rows;
    return rows.map((row) {
      final id = (row['id'] ?? '').toString().trim();
      final nameKey = _amenityStatusOverrideNameKey(row['name']);
      final override = (id.isNotEmpty ? overrides[id] : null) ??
          (nameKey.isNotEmpty ? overrides[nameKey] : null);
      if (override == null) return row;
      return <String, dynamic>{...row, 'status': override};
    }).toList();
  }

  bool _isLikelyNetworkError(Object error) {
    final msg = error.toString().toLowerCase();
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
    return markers.any(msg.contains);
  }

  bool _isProjectRowMissingForSync(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('project_row_missing_for_sync') ||
        (msg.contains('foreign key constraint') &&
            (msg.contains('project_id') || msg.contains('layout_id'))) ||
        msg.contains('violates foreign key constraint');
  }

  Map<String, dynamic>? _normalizePendingAmenityQueueEntry(dynamic raw) {
    if (raw is! Map) return null;
    final amenityId = (raw['amenityId'] ?? '').toString().trim();
    if (amenityId.isEmpty) return null;
    final parsedPayment = _parseAmenityPaymentStorageValue(raw['payment']);
    final paymentAmount = _parseMoneyLikeValue(
      raw['paymentAmount'] ?? raw['payment_amount'],
    );
    return <String, dynamic>{
      'amenityId': amenityId,
      'name': (raw['name'] ?? '').toString(),
      'area': (raw['area'] ?? '0').toString(),
      'allInCost': (raw['allInCost'] ?? raw['all_in_cost'] ?? '').toString(),
      'status': (raw['status'] ?? 'available').toString(),
      'salePrice': raw['salePrice'],
      'saleValue': raw['saleValue'],
      'buyerName': raw['buyerName'],
      'buyerContactNumber': raw['buyerContactNumber'],
      'payment': _buildAmenityPaymentStorageValue(
        methodsText: (parsedPayment['methods'] ?? '').toString(),
        totalPaidAmount: paymentAmount > 0
            ? paymentAmount
            : ((parsedPayment['amount'] as double?) ?? 0.0),
      ),
      'paymentAmount': paymentAmount > 0
          ? paymentAmount
          : ((parsedPayment['amount'] as double?) ?? 0.0),
      'agentName': raw['agentName'],
      'saleDate': raw['saleDate'],
      'queuedAtMs': (raw['queuedAtMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      'attempts': (raw['attempts'] as num?)?.toInt() ?? 0,
      'lastError': (raw['lastError'] ?? '').toString(),
    };
  }

  Future<List<Map<String, dynamic>>> _loadPendingAmenitySyncQueue({
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return <Map<String, dynamic>>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(
        _pendingAmenitySyncQueueKeyForProject(normalizedProjectId),
      );
      if (raw == null || raw.trim().isEmpty) {
        return <Map<String, dynamic>>[];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .map<Map<String, dynamic>?>(
              (entry) => _normalizePendingAmenityQueueEntry(entry))
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _persistPendingAmenitySyncQueue({
    required String projectId,
    required List<Map<String, dynamic>> queue,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _pendingAmenitySyncQueueKeyForProject(normalizedProjectId);
      if (queue.isEmpty) {
        await prefs.remove(key);
        return;
      }
      final payload = queue
          .map<Map<String, dynamic>>((entry) => <String, dynamic>{
                ...entry,
                'amenityId': (entry['amenityId'] ?? '').toString().trim(),
                'name': (entry['name'] ?? '').toString(),
                'area': (entry['area'] ?? '0').toString(),
                'allInCost': (entry['allInCost'] ?? '').toString(),
                'status': (entry['status'] ?? 'available').toString(),
                'buyerName': entry['buyerName'],
                'buyerContactNumber': entry['buyerContactNumber'],
                'payment': entry['payment'],
                'paymentAmount': entry['paymentAmount'],
                'agentName': entry['agentName'],
                'saleDate': entry['saleDate'],
                'salePrice': entry['salePrice'],
                'saleValue': entry['saleValue'],
                'queuedAtMs': (entry['queuedAtMs'] as num?)?.toInt() ??
                    DateTime.now().millisecondsSinceEpoch,
                'attempts': (entry['attempts'] as num?)?.toInt() ?? 0,
                'lastError': (entry['lastError'] ?? '').toString(),
              })
          .toList(growable: false);
      await prefs.setString(key, jsonEncode(payload));
    } catch (_) {
      // Best-effort persistence.
    }
  }

  Future<bool> _hasPendingAmenitySyncQueue({
    required String projectId,
  }) async {
    final queue = await _loadPendingAmenitySyncQueue(projectId: projectId);
    return queue.isNotEmpty;
  }

  Future<void> _upsertPendingAmenitySyncQueueEntry({
    required String projectId,
    required Map<String, dynamic> entry,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    final normalizedEntry = _normalizePendingAmenityQueueEntry(entry);
    if (normalizedEntry == null) return;
    final queue = await _loadPendingAmenitySyncQueue(
      projectId: normalizedProjectId,
    );
    final amenityId = (normalizedEntry['amenityId'] ?? '').toString().trim();
    if (amenityId.isEmpty) return;
    final existingIndex =
        queue.indexWhere((item) => (item['amenityId'] ?? '') == amenityId);
    if (existingIndex >= 0) {
      queue[existingIndex] = normalizedEntry;
    } else {
      queue.add(normalizedEntry);
    }
    await _persistPendingAmenitySyncQueue(
      projectId: normalizedProjectId,
      queue: queue,
    );
  }

  Future<List<Map<String, dynamic>>> _loadAmenitySnapshotRows({
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return <Map<String, dynamic>>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw =
          prefs.getString(_amenitySnapshotKeyForProject(normalizedProjectId));
      if (raw == null || raw.trim().isEmpty) {
        return <Map<String, dynamic>>[];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map<Map<String, dynamic>>(
              (row) => Map<String, dynamic>.from(row.cast<String, dynamic>()))
          .toList(growable: false);
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _persistAmenitySnapshotRows({
    required String projectId,
    required List<Map<String, dynamic>> rows,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _amenitySnapshotKeyForProject(normalizedProjectId);
      if (rows.isEmpty) {
        await prefs.remove(key);
        return;
      }
      await prefs.setString(
        key,
        jsonEncode(rows),
      );
    } catch (_) {
      // Best-effort snapshot only.
    }
  }

  Map<String, dynamic> _amenitySnapshotRowFromUiRow(Map<String, dynamic> area) {
    final status = _parsePlotStatus(area['status']);
    final areaValue = _parseMoneyLikeValue(area['area']);
    final allInCostValue =
        _parseMoneyLikeValue(area['allInCost'] ?? area['all_in_cost']);
    final salePriceValue = _parseMoneyLikeValue(area['salePrice']);
    final saleValueValue = _parseMoneyLikeValue(area['saleValue']);
    final paymentText = (area['payment'] ?? '').toString().trim();
    final paidAmount = _resolveAmenityPaidAmount(area);
    return <String, dynamic>{
      'id': (area['id'] ?? '').toString().trim(),
      'name': (area['name'] ?? '').toString().trim(),
      'area': areaValue,
      'all_in_cost': allInCostValue > 0 ? allInCostValue : null,
      'status': _plotStatusToDatabaseValue(status),
      'sale_price': salePriceValue > 0 ? salePriceValue : null,
      'sale_value': saleValueValue > 0 ? saleValueValue : null,
      'buyer_name': (area['buyerName'] ?? '').toString().trim().isEmpty
          ? null
          : (area['buyerName'] ?? '').toString().trim(),
      'buyer_contact_number':
          (area['buyerContactNumber'] ?? '').toString().trim().isEmpty
              ? null
              : (area['buyerContactNumber'] ?? '').toString().trim(),
      'payment': paymentText.isEmpty ? null : paymentText,
      'payment_amount': paidAmount > 0 ? paidAmount : null,
      'agent_name': (area['agent'] ?? '').toString().trim().isEmpty
          ? null
          : (area['agent'] ?? '').toString().trim(),
      'sale_date':
          _formatDateForDatabase((area['saleDate'] ?? '').toString().trim()),
    };
  }

  Future<void> _persistAmenitySnapshotFromCurrentState() async {
    final projectId = widget.projectId?.trim() ?? '';
    if (projectId.isEmpty) return;
    final rows = _amenityAreas
        .map<Map<String, dynamic>>(_amenitySnapshotRowFromUiRow)
        .where((row) {
      final id = (row['id'] ?? '').toString().trim();
      final name = (row['name'] ?? '').toString().trim();
      final area = _parseMoneyLikeValue(row['area']);
      final allInCost = _parseMoneyLikeValue(row['all_in_cost']);
      final status = _parsePlotStatus(row['status']);
      return id.isNotEmpty ||
          name.isNotEmpty ||
          area > 0 ||
          allInCost > 0 ||
          status != PlotStatus.available;
    }).toList(growable: false);
    await _persistAmenitySnapshotRows(projectId: projectId, rows: rows);
  }

  List<Map<String, String>> _buildAmenityAreasStoragePayload() {
    final payload = <Map<String, String>>[];
    for (final area in _amenityAreas) {
      final id = (area['id'] ?? '').toString().trim();
      final name = (area['name'] ?? '').toString().trim();
      final areaSqft = _parseMoneyLikeValue(area['area']);
      final allInCostSqft =
          _parseMoneyLikeValue(area['allInCost'] ?? area['all_in_cost']);
      final status =
          _plotStatusToDatabaseValue(_parsePlotStatus(area['status']));
      final salePriceValue =
          _parseMoneyLikeValue(area['salePrice'] ?? area['sale_price']);
      final saleValueValue =
          _parseMoneyLikeValue(area['saleValue'] ?? area['sale_value']);
      final buyerName =
          (area['buyerName'] ?? area['buyer_name'] ?? '').toString().trim();
      final buyerContactNumber = (area['buyerContactNumber'] ??
              area['buyer_contact_number'] ??
              area['buyer_mobile_number'] ??
              '')
          .toString()
          .trim();
      final paymentText = (area['payment'] ?? '').toString().trim();
      final paymentAmountValue = _resolveAmenityPaidAmount(area);
      final agentName =
          (area['agent'] ?? area['agentName'] ?? area['agent_name'] ?? '')
              .toString()
              .trim();
      final saleDateRaw =
          (area['saleDate'] ?? area['sale_date'] ?? '').toString().trim();
      final saleDateDb = _formatDateForDatabase(saleDateRaw) ?? '';
      final hasMeaningfulInput = id.isNotEmpty ||
          name.isNotEmpty ||
          areaSqft > 0 ||
          allInCostSqft > 0 ||
          status != 'available' ||
          salePriceValue > 0 ||
          saleValueValue > 0 ||
          buyerName.isNotEmpty ||
          buyerContactNumber.isNotEmpty ||
          paymentText.isNotEmpty ||
          paymentAmountValue > 0 ||
          agentName.isNotEmpty ||
          saleDateDb.isNotEmpty;
      if (!hasMeaningfulInput) continue;
      payload.add(<String, String>{
        'id': id,
        'name': name,
        'area': _formatWithFixedDecimals(areaSqft, 3),
        'allInCost': _formatWithFixedDecimals(allInCostSqft, 3),
        'status': status,
        'salePrice': salePriceValue > 0
            ? _formatWithFixedDecimals(salePriceValue, 2)
            : '',
        'saleValue': saleValueValue > 0
            ? _formatWithFixedDecimals(saleValueValue, 2)
            : '',
        'buyerName': buyerName,
        'buyerContactNumber': buyerContactNumber,
        'payment': paymentText,
        'paymentAmount': paymentAmountValue > 0
            ? _formatWithFixedDecimals(paymentAmountValue, 2)
            : '',
        'agentName': agentName,
        'saleDate': saleDateDb,
      });
    }
    return payload;
  }

  Future<void> _persistAmenityAreasToProjectStorage({
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    final payload = _buildAmenityAreasStoragePayload();
    await ProjectStorageService.saveProjectData(
      projectId: normalizedProjectId,
      projectName: '',
      amenityAreas: payload,
    );
  }

  /// Merges [snapshotRows] (locally persisted state) into [dbRows] (from DB)
  /// using a "don't downgrade" guard: a snapshot row may only raise a status
  /// (e.g. available → sold/reserved) or keep it the same. It will never
  /// lower a non-available status back to available unless the snapshot also
  /// carries sales-signal data, preventing stale DB reads from wiping edits.
  List<Map<String, dynamic>> _mergeSnapshotIntoAmenityRows({
    required List<Map<String, dynamic>> dbRows,
    required List<Map<String, dynamic>> snapshotRows,
  }) {
    if (snapshotRows.isEmpty) return dbRows;

    final merged = dbRows.map((r) => Map<String, dynamic>.from(r)).toList();
    final indexById = <String, int>{};
    final indexByName = <String, int>{};

    String nameKey(dynamic v) => (v ?? '').toString().trim().toLowerCase();

    for (var i = 0; i < merged.length; i++) {
      final id = (merged[i]['id'] ?? '').toString().trim();
      if (id.isNotEmpty) {
        indexById[id] = i;
      } else {
        final nk = nameKey(merged[i]['name']);
        if (nk.isNotEmpty) indexByName[nk] = i;
      }
    }

    bool hasSalesSignal(Map<String, dynamic> row) {
      final salePrice =
          _parseMoneyLikeValue(row['sale_price'] ?? row['salePrice']);
      final saleValue =
          _parseMoneyLikeValue(row['sale_value'] ?? row['saleValue']);
      final paymentAmount =
          _parseMoneyLikeValue(row['payment_amount'] ?? row['paymentAmount']);
      final buyerName =
          (row['buyer_name'] ?? row['buyerName'] ?? '').toString().trim();
      final saleDate =
          (row['sale_date'] ?? row['saleDate'] ?? '').toString().trim();
      final paymentText = (row['payment'] ?? '').toString().trim();
      final agentName =
          (row['agent_name'] ?? row['agentName'] ?? '').toString().trim();
      return salePrice > 0 ||
          saleValue > 0 ||
          paymentAmount > 0 ||
          buyerName.isNotEmpty ||
          saleDate.isNotEmpty ||
          paymentText.isNotEmpty ||
          agentName.isNotEmpty;
    }

    String resolveStatus(Map<String, dynamic> row) {
      final raw =
          (row['status'] ?? 'available').toString().trim().toLowerCase();
      if (raw == 'sold') return 'sold';
      if (raw == 'reserved' || raw == 'pending' || raw == 'blocked') {
        return 'reserved';
      }
      return 'available';
    }

    Map<String, dynamic> sanitizeSnapshotOverlay({
      required Map<String, dynamic> existing,
      required Map<String, dynamic> incoming,
      required String incomingStatus,
      required bool allowStatusDowngrade,
    }) {
      final sanitized = <String, dynamic>{};

      dynamic firstKeyValue(List<String> keys) {
        for (final key in keys) {
          if (incoming.containsKey(key)) return incoming[key];
        }
        return null;
      }

      bool hasAnyKey(List<String> keys) {
        for (final key in keys) {
          if (incoming.containsKey(key)) return true;
        }
        return false;
      }

      void setTextField({
        required List<String> sourceKeys,
        required String targetKey,
      }) {
        if (!hasAnyKey(sourceKeys)) return;
        final value = (firstKeyValue(sourceKeys) ?? '').toString().trim();
        if (value.isNotEmpty) {
          sanitized[targetKey] = value;
        }
      }

      void setNumberField({
        required List<String> sourceKeys,
        required String targetKey,
        required bool allowClear,
      }) {
        if (!hasAnyKey(sourceKeys)) return;
        final parsed = _parseMoneyLikeValue(firstKeyValue(sourceKeys));
        if (parsed > 0) {
          sanitized[targetKey] = parsed;
        }
      }

      final incomingId = (incoming['id'] ?? '').toString().trim();
      if (incomingId.isNotEmpty) {
        sanitized['id'] = incomingId;
      }

      final incomingName = (incoming['name'] ?? '').toString().trim();
      if (incomingName.isNotEmpty) {
        sanitized['name'] = incomingName;
      }

      setNumberField(
        sourceKeys: const ['area'],
        targetKey: 'area',
        allowClear: false,
      );
      setNumberField(
        sourceKeys: const ['all_in_cost', 'allInCost'],
        targetKey: 'all_in_cost',
        allowClear: false,
      );

      if (incoming.containsKey('status') && allowStatusDowngrade) {
        sanitized['status'] = incomingStatus;
      }

      setNumberField(
        sourceKeys: const ['sale_price', 'salePrice'],
        targetKey: 'sale_price',
        allowClear: false,
      );
      setNumberField(
        sourceKeys: const ['sale_value', 'saleValue'],
        targetKey: 'sale_value',
        allowClear: false,
      );
      setTextField(
        sourceKeys: const ['buyer_name', 'buyerName'],
        targetKey: 'buyer_name',
      );
      setTextField(
        sourceKeys: const ['payment'],
        targetKey: 'payment',
      );
      setNumberField(
        sourceKeys: const ['payment_amount', 'paymentAmount'],
        targetKey: 'payment_amount',
        allowClear: false,
      );
      setTextField(
        sourceKeys: const ['agent_name', 'agentName', 'agent'],
        targetKey: 'agent_name',
      );
      setTextField(
        sourceKeys: const ['sale_date', 'saleDate'],
        targetKey: 'sale_date',
      );

      final hasContactValue = hasAnyKey(
        const [
          'buyer_contact_number',
          'buyer_mobile_number',
          'buyerContactNumber'
        ],
      );
      if (hasContactValue) {
        final contactValue = (firstKeyValue(
                  const [
                    'buyer_contact_number',
                    'buyer_mobile_number',
                    'buyerContactNumber'
                  ],
                ) ??
                '')
            .toString()
            .trim();
        if (contactValue.isNotEmpty) {
          final usesMobileColumn = existing.containsKey('buyer_mobile_number');
          sanitized[usesMobileColumn
              ? 'buyer_mobile_number'
              : 'buyer_contact_number'] = contactValue;
        }
      }

      return sanitized;
    }

    for (final snapRow in snapshotRows) {
      final id = (snapRow['id'] ?? '').toString().trim();
      final nk = nameKey(snapRow['name']);
      final existingIndex = id.isNotEmpty
          ? (indexById[id] ?? (nk.isNotEmpty ? indexByName[nk] : null))
          : (nk.isNotEmpty ? indexByName[nk] : null);

      if (existingIndex == null) continue; // don't add new rows from snapshot

      final existing = merged[existingIndex];
      final existingStatus = resolveStatus(existing);
      final snapStatus = resolveStatus(snapRow);

      // Guard: if snapshot says "available" but existing is sold/reserved,
      // only allow the downgrade if the snapshot carries actual sales data.
      final allowStatusDowngrade = !(existingStatus != 'available' &&
          snapStatus == 'available' &&
          !hasSalesSignal(snapRow));
      if (existingStatus != 'available' &&
          snapStatus == 'available' &&
          !hasSalesSignal(snapRow)) {
        // Snapshot is stale — skip it entirely for this row.
        continue;
      }

      final overlay = sanitizeSnapshotOverlay(
        existing: existing,
        incoming: snapRow,
        incomingStatus: snapStatus,
        allowStatusDowngrade: allowStatusDowngrade,
      );
      if (overlay.isEmpty) continue;

      merged[existingIndex] = <String, dynamic>{
        ...existing,
        ...overlay,
      };
      // Preserve the id in case snapshot row had it missing.
      if ((merged[existingIndex]['id'] ?? '').toString().trim().isEmpty &&
          id.isNotEmpty) {
        merged[existingIndex]['id'] = id;
      }
    }

    return merged;
  }

  bool _amenityRowsContainSaleColumnsData(List<Map<String, dynamic>> rows) {
    for (final row in rows) {
      final salePrice =
          _parseMoneyLikeValue(row['sale_price'] ?? row['salePrice']);
      final buyerName =
          (row['buyer_name'] ?? row['buyerName'] ?? '').toString().trim();
      final paymentText = (row['payment'] ?? '').toString().trim();
      final agentName =
          (row['agent_name'] ?? row['agentName'] ?? row['agent'] ?? '')
              .toString()
              .trim();
      final saleDate =
          (row['sale_date'] ?? row['saleDate'] ?? '').toString().trim();
      if (salePrice > 0 ||
          buyerName.isNotEmpty ||
          paymentText.isNotEmpty ||
          agentName.isNotEmpty ||
          saleDate.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  List<Map<String, dynamic>> _mergeAmenitySalesDetailsIntoRows({
    required List<Map<String, dynamic>> baseRows,
    required List<Map<String, dynamic>> detailRows,
  }) {
    if (baseRows.isEmpty || detailRows.isEmpty) return baseRows;

    final merged =
        baseRows.map((row) => Map<String, dynamic>.from(row)).toList();
    final indexById = <String, int>{};
    final indexByName = <String, int>{};

    String normalizeName(dynamic value) {
      return (value ?? '').toString().trim().toLowerCase();
    }

    for (var i = 0; i < merged.length; i++) {
      final id = (merged[i]['id'] ?? '').toString().trim().toLowerCase();
      if (id.isNotEmpty) {
        indexById[id] = i;
      }
      final nameKey = normalizeName(merged[i]['name']);
      if (nameKey.isNotEmpty && !indexByName.containsKey(nameKey)) {
        indexByName[nameKey] = i;
      }
    }

    void setNumericField({
      required Map<String, dynamic> target,
      required Map<String, dynamic> source,
      required List<String> sourceKeys,
      required String targetKey,
    }) {
      for (final key in sourceKeys) {
        if (!source.containsKey(key)) continue;
        final parsed = _parseMoneyLikeValue(source[key]);
        if (parsed > 0) {
          target[targetKey] = parsed;
        }
        return;
      }
    }

    void setTextField({
      required Map<String, dynamic> target,
      required Map<String, dynamic> source,
      required List<String> sourceKeys,
      required String targetKey,
    }) {
      for (final key in sourceKeys) {
        if (!source.containsKey(key)) continue;
        final value = (source[key] ?? '').toString().trim();
        if (value.isNotEmpty) {
          target[targetKey] = value;
        }
        return;
      }
    }

    for (final detailEntry in detailRows.asMap().entries) {
      final detail = detailEntry.value;
      final detailId = (detail['id'] ?? '').toString().trim().toLowerCase();
      final detailNameKey = normalizeName(detail['name']);
      int? existingIndex = detailId.isNotEmpty
          ? (indexById[detailId] ??
              (detailNameKey.isNotEmpty ? indexByName[detailNameKey] : null))
          : (detailNameKey.isNotEmpty ? indexByName[detailNameKey] : null);
      if (existingIndex == null &&
          detailEntry.key >= 0 &&
          detailEntry.key < merged.length) {
        // Fallback: preserve row-positioned sale details when ids/names drift.
        existingIndex = detailEntry.key;
      }
      if (existingIndex == null) continue;

      final target = merged[existingIndex];
      setNumericField(
        target: target,
        source: detail,
        sourceKeys: const ['sale_price', 'salePrice'],
        targetKey: 'sale_price',
      );
      setNumericField(
        target: target,
        source: detail,
        sourceKeys: const ['sale_value', 'saleValue'],
        targetKey: 'sale_value',
      );
      setTextField(
        target: target,
        source: detail,
        sourceKeys: const ['buyer_name', 'buyerName'],
        targetKey: 'buyer_name',
      );
      setTextField(
        target: target,
        source: detail,
        sourceKeys: const ['payment'],
        targetKey: 'payment',
      );
      setNumericField(
        target: target,
        source: detail,
        sourceKeys: const ['payment_amount', 'paymentAmount'],
        targetKey: 'payment_amount',
      );
      setTextField(
        target: target,
        source: detail,
        sourceKeys: const ['agent_name', 'agentName', 'agent'],
        targetKey: 'agent_name',
      );
      setTextField(
        target: target,
        source: detail,
        sourceKeys: const ['sale_date', 'saleDate'],
        targetKey: 'sale_date',
      );

      final contactValue = (detail['buyer_contact_number'] ??
              detail['buyer_mobile_number'] ??
              detail['buyerContactNumber'] ??
              '')
          .toString()
          .trim();
      if (contactValue.isNotEmpty) {
        if (target.containsKey('buyer_mobile_number')) {
          target['buyer_mobile_number'] = contactValue;
        } else {
          target['buyer_contact_number'] = contactValue;
        }
      }
    }

    return merged;
  }

  bool _shouldPersistAmenitySnapshotAfterLoad({
    required List<Map<String, dynamic>> previousSnapshotRows,
    required List<Map<String, dynamic>> nextSnapshotRows,
  }) {
    if (nextSnapshotRows.isEmpty) return false;
    if (previousSnapshotRows.isEmpty) return true;
    if (nextSnapshotRows.length != previousSnapshotRows.length) return true;
    final previousHasSale = _amenityRowsContainSaleColumnsData(
      previousSnapshotRows,
    );
    final nextHasSale = _amenityRowsContainSaleColumnsData(nextSnapshotRows);
    if (!previousHasSale && nextHasSale) return true;
    // Do not rewrite snapshot on every load if it doesn't improve richness.
    return false;
  }

  List<Map<String, dynamic>> _mergeAmenityDisplayRowsKeepDetails({
    required List<Map<String, dynamic>> incomingRows,
    required List<Map<String, dynamic>> existingRows,
  }) {
    if (incomingRows.isEmpty || existingRows.isEmpty) return incomingRows;
    final merged =
        incomingRows.map((row) => Map<String, dynamic>.from(row)).toList();
    final indexById = <String, int>{};
    final indexByName = <String, int>{};

    String normalize(dynamic value) {
      return (value ?? '').toString().trim().toLowerCase();
    }

    for (var i = 0; i < merged.length; i++) {
      final id = normalize(merged[i]['id']);
      if (id.isNotEmpty) {
        indexById[id] = i;
      }
      final nameKey = normalize(merged[i]['name']);
      if (nameKey.isNotEmpty && !indexByName.containsKey(nameKey)) {
        indexByName[nameKey] = i;
      }
    }

    void setTextIfMissing(
        Map<String, dynamic> target, Map<String, dynamic> source, String key) {
      final existing = (target[key] ?? '').toString().trim();
      if (existing.isNotEmpty) return;
      final value = (source[key] ?? '').toString().trim();
      if (value.isNotEmpty) {
        target[key] = value;
      }
    }

    void setNumericStringIfMissing(
      Map<String, dynamic> target,
      Map<String, dynamic> source,
      String key,
    ) {
      final targetValue = _parseMoneyLikeValue(target[key]);
      if (targetValue > 0) return;
      final sourceValue = _parseMoneyLikeValue(source[key]);
      if (sourceValue > 0) {
        target[key] = _formatWithFixedDecimals(sourceValue, 2);
      }
    }

    for (final entry in existingRows.asMap().entries) {
      final existing = entry.value;
      final id = normalize(existing['id']);
      final nameKey = normalize(existing['name']);
      int? targetIndex = id.isNotEmpty
          ? (indexById[id] ??
              (nameKey.isNotEmpty ? indexByName[nameKey] : null))
          : (nameKey.isNotEmpty ? indexByName[nameKey] : null);
      if (targetIndex == null && entry.key >= 0 && entry.key < merged.length) {
        targetIndex = entry.key;
      }
      if (targetIndex == null) continue;

      final target = merged[targetIndex];
      if ((target['id'] ?? '').toString().trim().isEmpty &&
          (existing['id'] ?? '').toString().trim().isNotEmpty) {
        target['id'] = (existing['id'] ?? '').toString().trim();
      }

      final incomingStatus = _parsePlotStatus(target['status']);
      final existingStatus = _parsePlotStatus(existing['status']);
      if (incomingStatus == PlotStatus.available &&
          existingStatus != PlotStatus.available) {
        target['status'] = existingStatus;
      }

      setNumericStringIfMissing(target, existing, 'salePrice');
      setNumericStringIfMissing(target, existing, 'saleValue');
      setTextIfMissing(target, existing, 'buyerName');
      setTextIfMissing(target, existing, 'buyerContactNumber');
      setTextIfMissing(target, existing, 'payment');
      setNumericStringIfMissing(target, existing, 'paymentAmount');
      setTextIfMissing(target, existing, 'agent');
      setTextIfMissing(target, existing, 'saleDate');
    }

    return merged;
  }

  void _debugLogAmenityRows(String stage, List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      print('AmenityDebug[$stage]: rows=0');
      return;
    }
    Map<String, dynamic> chosen = rows.first;
    for (final row in rows) {
      final hasSignal = _parseMoneyLikeValue(
                row['sale_price'] ?? row['salePrice'],
              ) >
              0 ||
          (row['buyer_name'] ?? row['buyerName'] ?? '')
              .toString()
              .trim()
              .isNotEmpty ||
          (row['agent_name'] ?? row['agentName'] ?? row['agent'] ?? '')
              .toString()
              .trim()
              .isNotEmpty ||
          (row['sale_date'] ?? row['saleDate'] ?? '')
              .toString()
              .trim()
              .isNotEmpty;
      if (hasSignal) {
        chosen = row;
        break;
      }
    }
    final name = (chosen['name'] ?? '').toString().trim();
    final id = (chosen['id'] ?? '').toString().trim();
    final status = (chosen['status'] ?? '').toString().trim();
    final salePrice =
        (chosen['sale_price'] ?? chosen['salePrice'] ?? '').toString().trim();
    final buyer =
        (chosen['buyer_name'] ?? chosen['buyerName'] ?? '').toString().trim();
    final agent =
        (chosen['agent_name'] ?? chosen['agentName'] ?? chosen['agent'] ?? '')
            .toString()
            .trim();
    final saleDate =
        (chosen['sale_date'] ?? chosen['saleDate'] ?? '').toString().trim();
    print(
      'AmenityDebug[$stage]: rows=${rows.length}, id=$id, name="$name", status=$status, salePrice="$salePrice", buyer="$buyer", agent="$agent", saleDate="$saleDate"',
    );
  }

  List<Map<String, dynamic>> _applyPendingAmenitySyncQueueToRows(
    List<Map<String, dynamic>> sourceRows,
    List<Map<String, dynamic>> queue,
  ) {
    if (queue.isEmpty) return sourceRows;
    final merged = <Map<String, dynamic>>[];
    final indexById = <String, int>{};
    final indexByMissingIdName = <String, int>{};

    String normalizeNameKey(dynamic value) {
      return (value ?? '').toString().trim().toLowerCase();
    }

    void indexRow(Map<String, dynamic> row, int index) {
      indexById.removeWhere((_, storedIndex) => storedIndex == index);
      indexByMissingIdName
          .removeWhere((_, storedIndex) => storedIndex == index);
      final id = (row['id'] ?? '').toString().trim();
      if (id.isNotEmpty) {
        indexById[id] = index;
        return;
      }
      final nameKey = normalizeNameKey(row['name']);
      if (nameKey.isNotEmpty) {
        indexByMissingIdName[nameKey] = index;
      }
    }

    int? findExistingIndex({
      required String id,
      required String nameKey,
      int? preferredIndex,
    }) {
      if (id.isNotEmpty) {
        final byId = indexById[id];
        if (byId != null) return byId;
        if (nameKey.isNotEmpty) {
          final byMissingIdName = indexByMissingIdName[nameKey];
          if (byMissingIdName != null) return byMissingIdName;
        }
        if (preferredIndex != null &&
            preferredIndex >= 0 &&
            preferredIndex < merged.length) {
          final candidateId =
              (merged[preferredIndex]['id'] ?? '').toString().trim();
          if (candidateId.isEmpty) return preferredIndex;
        }
        return null;
      }
      if (nameKey.isNotEmpty) {
        return indexByMissingIdName[nameKey];
      }
      return null;
    }

    for (final entry in sourceRows.asMap().entries) {
      final sourceRow = entry.value;
      final row = Map<String, dynamic>.from(sourceRow);
      final id = (row['id'] ?? '').toString().trim();
      final nameKey = normalizeNameKey(row['name']);
      final existingIndex = findExistingIndex(
        id: id,
        nameKey: nameKey,
        preferredIndex: entry.key,
      );
      if (existingIndex == null) {
        merged.add(row);
        indexRow(row, merged.length - 1);
      } else {
        final mergedRow = <String, dynamic>{
          ...merged[existingIndex],
          ...row,
        };
        if ((mergedRow['id'] ?? '').toString().trim().isEmpty &&
            id.isNotEmpty) {
          mergedRow['id'] = id;
        }
        merged[existingIndex] = mergedRow;
        indexRow(mergedRow, existingIndex);
      }
    }

    for (final entry in queue) {
      final amenityId = (entry['amenityId'] ?? '').toString().trim();
      final entryName = (entry['name'] ?? '').toString().trim();
      final nameKey = normalizeNameKey(entryName);
      final existingIndex = findExistingIndex(
        id: amenityId,
        nameKey: nameKey,
      );
      final row = existingIndex != null
          ? merged[existingIndex]
          : <String, dynamic>{
              'id': amenityId,
              'name': entryName,
              'area': _parseMoneyLikeValue(entry['area']),
            };

      if (entryName.isNotEmpty) {
        row['name'] = entryName;
      }
      if ((row['id'] ?? '').toString().trim().isEmpty && amenityId.isNotEmpty) {
        row['id'] = amenityId;
      }

      row['status'] =
          (entry['status'] ?? row['status'] ?? 'available').toString().trim();
      final queuedAllInCost =
          _parseMoneyLikeValue(entry['allInCost'] ?? entry['all_in_cost']);
      if (queuedAllInCost > 0) {
        row['all_in_cost'] = queuedAllInCost;
      }
      final queuedSalePrice = _parseMoneyLikeValue(entry['salePrice']);
      if (queuedSalePrice > 0) {
        row['sale_price'] = queuedSalePrice;
      }
      final queuedSaleValue = _parseMoneyLikeValue(entry['saleValue']);
      if (queuedSaleValue > 0) {
        row['sale_value'] = queuedSaleValue;
      }
      final queuedBuyerName = (entry['buyerName'] ?? '').toString().trim();
      if (queuedBuyerName.isNotEmpty) {
        row['buyer_name'] = queuedBuyerName;
      }
      final queuedPayment = (entry['payment'] ?? '').toString().trim();
      if (queuedPayment.isNotEmpty) {
        row['payment'] = queuedPayment;
      }
      final queuedPaymentAmount = _parseMoneyLikeValue(
        entry['paymentAmount'] ?? entry['payment_amount'],
      );
      if (queuedPaymentAmount > 0) {
        row['payment_amount'] = queuedPaymentAmount;
      }
      final queuedAgentName = (entry['agentName'] ?? '').toString().trim();
      if (queuedAgentName.isNotEmpty) {
        row['agent_name'] = queuedAgentName;
      }
      final queuedSaleDate = (entry['saleDate'] ?? '').toString().trim();
      if (queuedSaleDate.isNotEmpty) {
        row['sale_date'] = queuedSaleDate;
      }

      final contactValue = entry['buyerContactNumber'];
      if (row.containsKey('buyer_contact_number')) {
        final normalized = (contactValue ?? '').toString().trim();
        if (normalized.isNotEmpty) {
          row['buyer_contact_number'] = normalized;
        }
      } else if (row.containsKey('buyer_mobile_number')) {
        final normalized = (contactValue ?? '').toString().trim();
        if (normalized.isNotEmpty) {
          row['buyer_mobile_number'] = normalized;
        }
      } else {
        final normalized = (contactValue ?? '').toString().trim();
        if (normalized.isNotEmpty) {
          row['buyer_contact_number'] = normalized;
        }
      }

      if (existingIndex == null) {
        merged.add(row);
        indexRow(row, merged.length - 1);
      } else {
        merged[existingIndex] = row;
        indexRow(row, existingIndex);
      }
    }
    return merged;
  }

  Map<String, dynamic> _buildAmenityRemoteUpdateDataFromQueueEntry(
    Map<String, dynamic> entry, {
    required String? buyerContactColumnName,
  }) {
    final salePriceValue = _parseMoneyLikeValue(entry['salePrice']);
    final saleValue = _parseMoneyLikeValue(entry['saleValue']);
    final buyerName = (entry['buyerName'] ?? '').toString().trim();
    final buyerContactNumber =
        (entry['buyerContactNumber'] ?? '').toString().trim();
    final parsedPayment = _parseAmenityPaymentStorageValue(entry['payment']);
    final explicitPaymentAmount = _parseMoneyLikeValue(
      entry['paymentAmount'] ?? entry['payment_amount'],
    );
    final totalPaidAmount = explicitPaymentAmount > 0
        ? explicitPaymentAmount
        : ((parsedPayment['amount'] as double?) ?? 0.0);
    final payment = _buildAmenityPaymentStorageValue(
      methodsText: (parsedPayment['methods'] ?? '').toString(),
      totalPaidAmount: totalPaidAmount,
    );
    final agentName = (entry['agentName'] ?? '').toString().trim();
    final saleDate = (entry['saleDate'] ?? '').toString().trim();
    final normalizedStatus =
        (entry['status'] ?? 'available').toString().trim().toLowerCase();
    final shouldClearForAvailable = normalizedStatus == 'available';
    final updateData = <String, dynamic>{
      'updated_at': DateTime.now().toIso8601String(),
      'status': (entry['status'] ?? 'available').toString().trim().isEmpty
          ? 'available'
          : (entry['status'] ?? 'available').toString().trim(),
    };
    if (salePriceValue > 0) {
      updateData['sale_price'] = salePriceValue;
    } else if (shouldClearForAvailable) {
      updateData['sale_price'] = null;
    }
    if (saleValue > 0) {
      updateData['sale_value'] = saleValue;
    } else if (shouldClearForAvailable) {
      updateData['sale_value'] = null;
    }
    if (buyerName.isNotEmpty) {
      updateData['buyer_name'] = buyerName;
    } else if (shouldClearForAvailable) {
      updateData['buyer_name'] = null;
    }
    if (payment.isNotEmpty) {
      updateData['payment'] = payment;
    } else if (shouldClearForAvailable) {
      updateData['payment'] = null;
    }
    if (agentName.isNotEmpty) {
      updateData['agent_name'] = agentName;
    } else if (shouldClearForAvailable) {
      updateData['agent_name'] = null;
    }
    if (saleDate.isNotEmpty) {
      updateData['sale_date'] = saleDate;
    } else if (shouldClearForAvailable) {
      updateData['sale_date'] = null;
    }
    if (buyerContactNumber.isNotEmpty && buyerContactColumnName == null) {
      throw StateError('Could not resolve amenity buyer contact column');
    }
    if (buyerContactColumnName != null && buyerContactColumnName.isNotEmpty) {
      if (buyerContactNumber.isNotEmpty) {
        updateData[buyerContactColumnName] = buyerContactNumber;
      } else if (shouldClearForAvailable) {
        updateData[buyerContactColumnName] = null;
      }
    }
    return updateData;
  }

  Future<bool> _flushPendingAmenitySyncQueue({
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return true;

    final queue = await _loadPendingAmenitySyncQueue(
      projectId: normalizedProjectId,
    );
    if (queue.isEmpty) return true;
    final statusOverrides = await _loadAmenityStatusOverrides(
      projectId: normalizedProjectId,
    );

    String? buyerContactColumnName;
    try {
      buyerContactColumnName = await _resolveAmenityBuyerContactColumnName();
    } catch (_) {
      // Keep queue item and retry when online.
    }

    final remaining = <Map<String, dynamic>>[];
    var hadSuccessfulSync = false;
    for (int index = 0; index < queue.length; index++) {
      final originalEntry = queue[index];
      final entry = Map<String, dynamic>.from(originalEntry);
      final amenityId = (entry['amenityId'] ?? '').toString().trim();
      if (amenityId.isEmpty) continue;
      final nameKey = _amenityStatusOverrideNameKey(entry['name']);
      final overrideStatus =
          (amenityId.isNotEmpty ? statusOverrides[amenityId] : null) ??
              (nameKey.isNotEmpty ? statusOverrides[nameKey] : null);
      if (overrideStatus != null && overrideStatus != 'available') {
        final queuedStatus =
            (entry['status'] ?? 'available').toString().trim().toLowerCase();
        if (queuedStatus == 'available') {
          entry['status'] = overrideStatus;
        }
      }
      try {
        final updateData = _buildAmenityRemoteUpdateDataFromQueueEntry(
          entry,
          buyerContactColumnName: buyerContactColumnName,
        );
        await _supabase
            .from('amenity_areas')
            .update(updateData)
            .eq('project_id', normalizedProjectId)
            .eq('id', amenityId);
        hadSuccessfulSync = true;
      } catch (e) {
        final failedEntry = Map<String, dynamic>.from(entry)
          ..['attempts'] = ((entry['attempts'] as num?)?.toInt() ?? 0) + 1
          ..['lastError'] = e.toString();
        remaining.add(failedEntry);
        if (_isLikelyNetworkError(e)) {
          for (int pendingIndex = index + 1;
              pendingIndex < queue.length;
              pendingIndex++) {
            remaining.add(Map<String, dynamic>.from(queue[pendingIndex]));
          }
          break;
        }
      }
    }

    await _persistPendingAmenitySyncQueue(
      projectId: normalizedProjectId,
      queue: remaining,
    );

    if (hadSuccessfulSync) {
      await _touchProjectUpdatedAt();
      await _markRemoteSaveTimestamp();
    }

    return remaining.isEmpty;
  }

  double _stepTableZoomLevel(double current, {required bool increase}) {
    final currentStep = (current * 10).round();
    final nextStep = (currentStep + (increase ? 1 : -1)).clamp(5, 12);
    return nextStep / 10.0;
  }

  Color _layoutControlBackground(String key) {
    return _layoutControlFlashKeys.contains(key)
        ? const Color(0xFFEDEDED)
        : Colors.white;
  }

  void _flashLayoutControl(String key) {
    if (!mounted) return;
    setState(() {
      _layoutControlFlashKeys.add(key);
    });
    _layoutControlFlashTimers[key]?.cancel();
    _layoutControlFlashTimers[key] = Timer(const Duration(seconds: 0), () {
      if (!mounted) return;
      setState(() {
        _layoutControlFlashKeys.remove(key);
      });
      _layoutControlFlashTimers.remove(key);
    });
  }

  void _handleLayoutControlTap(String key, VoidCallback action) {
    action();
    _flashLayoutControl(key);
  }

  void _setLayoutZoomPressed(String key, bool pressed) {
    if (!mounted) return;
    setState(() {
      if (pressed) {
        _layoutPressedZoomKeys.add(key);
      } else {
        _layoutPressedZoomKeys.remove(key);
      }
    });
  }

  void _handleMainScroll() {
    _scheduleLayoutsStickyStateUpdate();
  }

  void _scheduleLayoutsStickyStateUpdate() {
    if (!mounted || _stickyToolbarEvaluationScheduled) return;
    _stickyToolbarEvaluationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stickyToolbarEvaluationScheduled = false;
      if (!mounted) return;
      _updateLayoutsStickyState();
    });
  }

  void _updateLayoutsStickyState() {
    if (!mounted) return;

    final hasLayoutsForActiveTab =
        _activeContentTab == PlotStatusContentTab.site
            ? _layouts.isNotEmpty
            : _hasAmenityAreaData;
    if (!hasLayoutsForActiveTab) {
      if (_showStickyLayoutsToolbar) {
        setState(() {
          _showStickyLayoutsToolbar = false;
        });
      }
      return;
    }

    final toolbarContext = _layoutsToolbarAnchorKey.currentContext;
    final viewportContext = _contentViewportKey.currentContext;
    if (toolbarContext == null || viewportContext == null) return;

    final toolbarBox = toolbarContext.findRenderObject() as RenderBox?;
    final viewportBox = viewportContext.findRenderObject() as RenderBox?;
    if (toolbarBox == null || viewportBox == null) return;

    final toolbarTop = toolbarBox.localToGlobal(Offset.zero).dy;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final shouldStick = toolbarTop <= viewportTop;

    if (shouldStick != _showStickyLayoutsToolbar) {
      setState(() {
        _showStickyLayoutsToolbar = shouldStick;
      });
    }
  }

  String _normalizeSignatureText(dynamic value) {
    return (value ?? '').toString().trim();
  }

  String _normalizeSignatureNumeric(dynamic value) {
    final raw = _normalizeSignatureText(value)
        .replaceAll(',', '')
        .replaceAll('₹', '')
        .replaceAll(' ', '');
    if (raw.isEmpty) return '';
    final parsed = double.tryParse(raw);
    if (parsed == null) return raw.toLowerCase();
    return parsed.toStringAsFixed(4);
  }

  String _normalizeSignatureStatus(dynamic value) {
    final status = value is PlotStatus ? value : _parsePlotStatus(value);
    return _plotStatusToDatabaseValue(status);
  }

  String _normalizePaymentsSignature(dynamic value) {
    final payments = value is List ? value : const <dynamic>[];
    final normalized = payments.map((payment) {
      if (payment is Map) {
        final entries = payment.entries.toList()
          ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
        return <String, String>{
          for (final entry in entries)
            entry.key.toString(): _normalizeSignatureText(entry.value),
        };
      }
      return <String, String>{
        'value': _normalizeSignatureText(payment),
      };
    }).toList(growable: false);
    return jsonEncode(normalized);
  }

  String _layoutSignatureKey(Map<String, dynamic> layout) {
    final id = _normalizeSignatureText(layout['id']);
    if (id.isNotEmpty) return 'id:$id';
    final name = _normalizeSignatureText(layout['name']).toLowerCase();
    return 'name:$name';
  }

  String _plotSignatureKey(
    String layoutKey,
    Map<String, dynamic> plot,
    int fallbackIndex,
  ) {
    final id = _normalizeSignatureText(plot['id']);
    if (id.isNotEmpty) return 'id:$id';
    final plotNumber =
        _normalizeSignatureText(plot['plotNumber']).toLowerCase();
    if (plotNumber.isNotEmpty) return '$layoutKey|plot:$plotNumber';
    return '$layoutKey|idx:$fallbackIndex';
  }

  String _buildLayoutSignature(Map<String, dynamic> layout) {
    return [
      _normalizeSignatureText(layout['name']).toLowerCase(),
      _normalizeSignatureText(layout['layoutImageName']),
      _normalizeSignatureText(layout['layoutImagePath']),
      _normalizeSignatureText(layout['layoutImageDocId']),
      _normalizeSignatureText(layout['layoutImageExtension']).toLowerCase(),
    ].join('|');
  }

  String _buildPlotSignature(Map<String, dynamic> plot) {
    final partners = ((plot['partners'] as List?) ?? const [])
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false)
      ..sort();
    return [
      _normalizeSignatureText(plot['plotNumber']).toLowerCase(),
      _normalizeSignatureNumeric(plot['area']),
      _normalizeSignatureNumeric(plot['purchaseRate']),
      _normalizeSignatureNumeric(plot['totalPlotCost']),
      _normalizeSignatureStatus(plot['status']),
      _normalizeSignatureNumeric(plot['salePrice']),
      _normalizeSignatureText(plot['buyerName']).toLowerCase(),
      _normalizeSignatureText(plot['buyerContactNumber']),
      _normalizeSignatureText(plot['agent']).toLowerCase(),
      _normalizeSignatureText(plot['saleDate']),
      partners.join(','),
      _normalizePaymentsSignature(plot['payments']),
    ].join('|');
  }

  void _captureRemoteLayoutSignatures(List<Map<String, dynamic>> layouts) {
    _lastSyncedLayoutSignatures.clear();
    _lastSyncedPlotSignatures.clear();
    for (final layout in layouts) {
      final layoutKey = _layoutSignatureKey(layout);
      _lastSyncedLayoutSignatures[layoutKey] = _buildLayoutSignature(layout);
      final plots = layout['plots'] as List<dynamic>? ?? const <dynamic>[];
      for (var plotIndex = 0; plotIndex < plots.length; plotIndex++) {
        final plotRaw = plots[plotIndex];
        if (plotRaw is! Map) continue;
        final plot = Map<String, dynamic>.from(plotRaw);
        final plotKey = _plotSignatureKey(layoutKey, plot, plotIndex);
        _lastSyncedPlotSignatures[plotKey] = _buildPlotSignature(plot);
      }
    }
  }

  List<Map<String, dynamic>> _buildLayoutsDeltaForRemoteSave(
    List<Map<String, dynamic>> layouts,
  ) {
    final hasBaseline = _lastSyncedLayoutSignatures.isNotEmpty ||
        _lastSyncedPlotSignatures.isNotEmpty;
    if (!hasBaseline) {
      return layouts;
    }

    final changedLayouts = <Map<String, dynamic>>[];
    for (final layout in layouts) {
      final layoutKey = _layoutSignatureKey(layout);
      final layoutSignature = _buildLayoutSignature(layout);
      final layoutChanged =
          _lastSyncedLayoutSignatures[layoutKey] != layoutSignature;
      final plots = layout['plots'] as List<dynamic>? ?? const <dynamic>[];
      final changedPlots = <Map<String, dynamic>>[];

      for (var plotIndex = 0; plotIndex < plots.length; plotIndex++) {
        final plotRaw = plots[plotIndex];
        if (plotRaw is! Map) continue;
        final plot = Map<String, dynamic>.from(plotRaw);
        final plotKey = _plotSignatureKey(layoutKey, plot, plotIndex);
        final plotSignature = _buildPlotSignature(plot);
        if (_lastSyncedPlotSignatures[plotKey] != plotSignature) {
          changedPlots.add(plot);
        }
      }

      if (!layoutChanged && changedPlots.isEmpty) continue;

      changedLayouts.add({
        ...layout,
        'plots': changedPlots,
      });
    }

    return changedLayouts;
  }

  bool get _isEditingAmenityArea =>
      _editingAmenityAreaIndex != null && _amenityEditTempLayoutIndex != null;

  Future<String?> _resolveAmenityBuyerContactColumnName() async {
    if (_amenityBuyerContactColumnChecked) {
      return _amenityBuyerContactColumnName;
    }
    const candidates = <String>[
      'buyer_contact_number',
      'buyer_mobile_number',
    ];
    for (final column in candidates) {
      try {
        await _supabase.from('amenity_areas').select(column).limit(1);
        _amenityBuyerContactColumnName = column;
        break;
      } catch (_) {
        // Try next candidate.
      }
    }
    _amenityBuyerContactColumnChecked = true;
    return _amenityBuyerContactColumnName;
  }

  Future<String?> _resolvePlotsBuyerContactColumnName() async {
    if (_plotsBuyerContactColumnChecked) {
      return _plotsBuyerContactColumnName;
    }
    const candidates = <String>[
      'buyer_contact_number',
      'buyer_mobile_number',
    ];
    for (final column in candidates) {
      try {
        await _supabase.from('plots').select(column).limit(1);
        _plotsBuyerContactColumnName = column;
        break;
      } catch (_) {
        // Try next candidate.
      }
    }
    _plotsBuyerContactColumnChecked = true;
    return _plotsBuyerContactColumnName;
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

  void _rebuildAllPlotsFromLayouts({String reason = 'unknown'}) {
    print('🔨 REBUILD[$reason]: Starting full rebuild from _layouts');
    final rebuilt = <Map<String, dynamic>>[];
    for (var layoutIndex = 0; layoutIndex < _layouts.length; layoutIndex++) {
      final layout = _layouts[layoutIndex];
      final layoutName = layout['name'] as String? ?? '';
      final plots = _coerceMapList(layout['plots']);
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
        '🔨 REBUILD[$reason]: Completed. Total plots in _allPlots: ${_allPlots.length}');
  }

  void _removePaymentBlock(int paymentIndex) {
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;
    final payments = _ensureEditablePaymentsList(plot);
    if (paymentIndex >= 0 && paymentIndex < payments.length) {
      payments.removeAt(paymentIndex);
      _clearPaymentInputCachesForPlot(_editingLayoutIndex!, _editingPlotIndex!);
      setState(() {
        _syncEditingPlotToAllPlots();
      });
      _saveLayoutsData();
    }
  }

  void _clearPaymentInputCachesForPlot(int layoutIndex, int plotIndex) {
    final prefix = '${layoutIndex}_${plotIndex}_';

    final amountKeys = _paymentAmountControllers.keys
        .where((key) => key.startsWith(prefix))
        .toList();
    for (final key in amountKeys) {
      _paymentAmountControllers.remove(key)?.dispose();
      _paymentAmountFocusNodes.remove(key)?.dispose();
    }

    final textKeys = _paymentTextControllers.keys
        .where((key) => key.startsWith(prefix))
        .toList();
    for (final key in textKeys) {
      _paymentTextControllers.remove(key)?.dispose();
      _paymentTextFocusNodes.remove(key)?.dispose();
    }
  }

  void _collapsePaymentAmountSelectionForPlot(int layoutIndex, int plotIndex) {
    final prefix = '${layoutIndex}_${plotIndex}_';
    final amountKeys = _paymentAmountControllers.keys
        .where((key) => key.startsWith(prefix))
        .toList();
    for (final key in amountKeys) {
      final controller = _paymentAmountControllers[key];
      if (controller == null) continue;
      final text = controller.text;
      controller.value = controller.value.copyWith(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: TextRange.empty,
      );
      _paymentAmountFocusNodes[key]?.unfocus();
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
    _notifyEditDialogVisibilityChanged(false);
    _scrollController.addListener(_handleMainScroll);
    _setActiveContentTab(PlotStatusContentTab.site, persist: false);
    final normalizedProjectId = widget.projectId?.trim() ?? '';
    if (widget.isActive) {
      final restoredFromSession = _restoreSessionSnapshot(normalizedProjectId);
      if (!restoredFromSession) {
        _notifyLoadingState(true);
        _loadPlotDataAndNotify(showLoadingIndicator: true);
      } else {
        unawaited(
          _loadPlotDataAndNotify(
            showLoadingIndicator: false,
            forceRefresh: true,
          ),
        );
      }
    } else {
      // Hidden tabs should stay completely idle.
      // Do not restore/rebuild while hidden to avoid background churn.
      _isLoading = false;
      _notifyLoadingState(false);
    }
    _onlineSubscription = html.window.onOnline.listen((_) {
      _retrySaveOnReconnect();
    });
    _arrowKeyScrollBinding.attach();
  }

  @override
  void didUpdateWidget(covariant PlotStatusPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final becameActive = widget.isActive && !oldWidget.isActive;
    final currentProjectId = widget.projectId?.trim() ?? '';
    final previousProjectId = oldWidget.projectId?.trim() ?? '';
    final projectChanged = currentProjectId != previousProjectId;
    final isSameLoadedProject = currentProjectId.isNotEmpty &&
        currentProjectId == _lastLoadedProjectId &&
        _hasLoadedCurrentProjectOnce;
    final effectiveProjectChanged = projectChanged && !isSameLoadedProject;
    final layoutsChanged = widget.layouts != oldWidget.layouts;
    final agentsChanged = widget.agents != oldWidget.agents;
    final shouldReload =
        effectiveProjectChanged || layoutsChanged || agentsChanged;

    if (effectiveProjectChanged) {
      _hasLoadedCurrentProjectOnce = false;
      _lastLoadedProjectId = '';
      _resetPlotStatusViewForProjectChange(showLoading: widget.isActive);
    }

    if (!widget.isActive) {
      // Invalidate any in-flight load generation while hidden so hidden-page
      // loads do not continue applying or re-triggering UI churn.
      _plotDataLoadGeneration++;
      if (shouldReload) {
        _reloadWhenActivated = true;
      }
      return;
    }

    if (becameActive) {
      _setActiveContentTab(PlotStatusContentTab.site, persist: false);
      final hasInMemoryData = _layouts.isNotEmpty || _allPlots.isNotEmpty;
      final needsInitialLoad =
          !_hasLoadedCurrentProjectOnce && !hasInMemoryData;
      final shouldReloadOnActivate = effectiveProjectChanged ||
          (_reloadWhenActivated && !hasInMemoryData) ||
          needsInitialLoad;
      _reloadWhenActivated = false;
      if (!shouldReloadOnActivate) return;
      if (_restoreSessionSnapshot(currentProjectId)) {
        unawaited(
          _loadPlotDataAndNotify(
            showLoadingIndicator: false,
            forceRefresh: true,
          ),
        );
        return;
      }
      _loadPlotDataAndNotify(
        showLoadingIndicator: true,
        forceFullPageSkeleton: effectiveProjectChanged,
      );
      return;
    }
    if (!shouldReload) return;

    if (effectiveProjectChanged) {
      _setActiveContentTab(PlotStatusContentTab.site, persist: false);
    }
    _loadPlotDataAndNotify(
      showLoadingIndicator: effectiveProjectChanged || _layouts.isEmpty,
      forceFullPageSkeleton: effectiveProjectChanged,
    );
  }

  Future<void> _loadPlotDataAndNotify({
    bool showLoadingIndicator = true,
    int? generation,
    bool forceRefresh = false,
    bool forceFullPageSkeleton = false,
  }) async {
    if (!widget.isActive && !forceRefresh) {
      return;
    }
    final normalizedProjectId = widget.projectId?.trim() ?? '';
    if (!forceRefresh && generation == null && normalizedProjectId.isNotEmpty) {
      final inFlightLoad = _inFlightLoadByProject[normalizedProjectId];
      if (inFlightLoad != null) {
        try {
          await inFlightLoad;
        } catch (_) {}
        // Primary caller has already applied fresh state; do not re-apply a
        // snapshot here because that causes duplicate full rebuild cycles.
        return;
      }
    }
    if (!widget.isActive && !forceRefresh) {
      return;
    }
    final sameProjectAsLastLoad = normalizedProjectId.isNotEmpty &&
        normalizedProjectId == _lastLoadedProjectId;
    if (!forceRefresh &&
        generation == null &&
        sameProjectAsLastLoad &&
        _hasLoadedCurrentProjectOnce) {
      return;
    }
    if (_isLoadInProgress && generation == null && !forceRefresh) {
      return;
    }
    final loadGeneration = generation ?? ++_plotDataLoadGeneration;
    final forcedSkeletonStartedAt =
        (forceFullPageSkeleton && showLoadingIndicator) ? DateTime.now() : null;
    Future<void> ensureForcedSkeletonDelay() async {
      if (forcedSkeletonStartedAt == null) return;
      final elapsed = DateTime.now().difference(forcedSkeletonStartedAt);
      final remaining = _forcedRefreshSkeletonMin - elapsed;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }

    _isLoadInProgress = true;
    Completer<void>? sharedLoadCompleter;
    if (generation == null && normalizedProjectId.isNotEmpty) {
      sharedLoadCompleter = Completer<void>();
      _inFlightLoadByProject[normalizedProjectId] = sharedLoadCompleter.future;
    }
    if (normalizedProjectId.isNotEmpty) {
      // Do not block first paint on network/storage queue flushes.
      unawaited(
        ProjectStorageService.flushPendingSaves(
          projectId: normalizedProjectId,
        ).catchError((_) {}),
      );
      unawaited(
        _flushPendingAmenitySyncQueue(
          projectId: normalizedProjectId,
        ).catchError((_) {}),
      );
    }
    if (showLoadingIndicator) {
      if (mounted) {
        setState(() {
          _isLoading = true;
          if (forceFullPageSkeleton) {
            _forceShowFullPageLoadingSkeleton = true;
            _allPlots = <Map<String, dynamic>>[];
            _layouts = <Map<String, dynamic>>[];
            _amenityAreas = <Map<String, dynamic>>[];
            _storedAgents = <Map<String, dynamic>>[];
          }
        });
      } else {
        _isLoading = true;
        if (forceFullPageSkeleton) {
          _forceShowFullPageLoadingSkeleton = true;
          _allPlots = <Map<String, dynamic>>[];
          _layouts = <Map<String, dynamic>>[];
          _amenityAreas = <Map<String, dynamic>>[];
          _storedAgents = <Map<String, dynamic>>[];
        }
      }
      _notifyLoadingState(true);
    }
    try {
      await _loadPlotData(
        loadGeneration: loadGeneration,
        suppressEarlyLoadingRelease: forceFullPageSkeleton,
      );
      if (!mounted ||
          loadGeneration != _plotDataLoadGeneration ||
          (!widget.isActive && !forceRefresh)) {
        return;
      }
      _lastLoadedProjectId = normalizedProjectId;
      _hasLoadedCurrentProjectOnce = true;
      _cacheCurrentStateForSession(normalizedProjectId);

      final shouldRetryEmptyPlots = _layouts.isNotEmpty &&
          _allPlots.isEmpty &&
          _emptyPlotsLoadRetryCount < 2;
      if (shouldRetryEmptyPlots) {
        _emptyPlotsLoadRetryCount++;
        await Future<void>.delayed(const Duration(milliseconds: 450));
        if (mounted && (widget.isActive || forceRefresh)) {
          await _loadPlotDataAndNotify(
            showLoadingIndicator: showLoadingIndicator,
            generation: loadGeneration,
            forceRefresh: forceRefresh,
            forceFullPageSkeleton: forceFullPageSkeleton,
          );
        }
        return;
      }
      _emptyPlotsLoadRetryCount = 0;

      if (showLoadingIndicator) {
        await ensureForcedSkeletonDelay();
        if (mounted && _isLoading) setState(() => _isLoading = false);
        _notifyLoadingState(false);
      }
      if (normalizedProjectId.isNotEmpty) {
        try {
          final hasPendingOfflineSaves =
              await ProjectStorageService.hasPendingOfflineSaves(
            projectId: normalizedProjectId,
          );
          final hasPendingProjectCreate =
              await OfflineProjectSyncService.isPendingLocalProject(
            projectId: normalizedProjectId,
            userId: _supabase.auth.currentUser?.id,
          );
          final hasPendingOfflineSync =
              hasPendingOfflineSaves || hasPendingProjectCreate;
          final hasPendingAmenitySync = await _hasPendingAmenitySyncQueue(
            projectId: normalizedProjectId,
          );
          if (hasPendingOfflineSync || hasPendingAmenitySync) {
            _setSaveStatus(ProjectSaveStatusType.queuedOffline);
          }
        } catch (_) {
          // Keep current status when queue state lookup fails.
        }
      }
      _notifyErrorState();
    } finally {
      if (_forceShowFullPageLoadingSkeleton) {
        if (mounted) {
          setState(() {
            _forceShowFullPageLoadingSkeleton = false;
          });
        } else {
          _forceShowFullPageLoadingSkeleton = false;
        }
      }
      _isLoadInProgress = false;
      if (sharedLoadCompleter != null) {
        if (!sharedLoadCompleter.isCompleted) {
          sharedLoadCompleter.complete();
        }
        final inFlightLoad = _inFlightLoadByProject[normalizedProjectId];
        if (identical(inFlightLoad, sharedLoadCompleter.future)) {
          _inFlightLoadByProject.remove(normalizedProjectId);
        }
      }
    }
  }

  void _markLocalSaveCompleted() {
    _hasUnsavedChanges = false;
    _setSaveStatus(ProjectSaveStatusType.saved);
  }

  void _notifyErrorState() {
    if (!widget.isActive) return;
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
    var hasPendingAmenitySync = false;
    final normalizedProjectId = widget.projectId?.trim() ?? '';
    if (widget.projectId != null && widget.projectId!.trim().isNotEmpty) {
      try {
        await ProjectStorageService.flushPendingSaves(
          projectId: widget.projectId,
        );
      } catch (_) {
        // Best effort: page-level retry below still handles unsaved in-memory edits.
      }
      try {
        final queueDrained = await _flushPendingAmenitySyncQueue(
          projectId: normalizedProjectId,
        );
        hasPendingAmenitySync = !queueDrained;
      } catch (_) {
        hasPendingAmenitySync = await _hasPendingAmenitySyncQueue(
          projectId: normalizedProjectId,
        );
      }
    }
    if (_isAutoRetryInProgress) return;
    if (!_hasUnsavedChanges && !hasPendingAmenitySync) return;

    _isAutoRetryInProgress = true;
    try {
      if (_hasUnsavedChanges) {
        await _saveLayoutsData(immediate: true);
      }
      if (!_hasUnsavedChanges && !hasPendingAmenitySync) {
        _setSaveStatus(ProjectSaveStatusType.saved);
      }
    } finally {
      _isAutoRetryInProgress = false;
    }
  }

  @override
  void dispose() {
    _notifyEditDialogVisibilityChanged(false);
    for (final timer in _layoutControlFlashTimers.values) {
      timer.cancel();
    }
    _layoutControlFlashTimers.clear();
    _layoutControlFlashKeys.clear();
    _layoutPressedZoomKeys.clear();
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
    _layoutSaveDebounceTimer?.cancel();
    _queuedLayoutSaveCompleter = null;
    // Dispose scroll controllers
    _plotStatusTableScrollController.dispose();
    _amenityAreaTableScrollController.dispose();
    _editDialogScrollController.dispose();
    for (var controller in _layoutTableScrollControllers.values) {
      controller.dispose();
    }
    _layoutTableScrollControllers.clear();
    _onlineSubscription?.cancel();
    _scrollController.removeListener(_handleMainScroll);
    _arrowKeyScrollBinding.detach();
    super.dispose();
  }

  FocusNode _createDialogFocusNode() {
    final node = FocusNode();
    node.addListener(() {
      if (mounted) setState(() {});
    });
    return node;
  }

  void _resetBuyerNameFieldToStart(String fieldKey) {
    final controller = _buyerNameControllers[fieldKey];
    if (controller == null) return;
    controller.selection = const TextSelection.collapsed(offset: 0);
    _buyerNameFieldEpoch[fieldKey] = (_buyerNameFieldEpoch[fieldKey] ?? 0) + 1;
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

  List<Map<String, dynamic>> _ensureEditablePaymentsList(
      Map<String, dynamic> plot) {
    final rawPayments = plot['payments'];
    if (rawPayments is List) {
      final normalized = <Map<String, dynamic>>[];
      for (final payment in rawPayments) {
        if (payment is Map<String, dynamic>) {
          // Keep the same map reference so text-field callbacks keep writing
          // to the currently rendered payment entry.
          normalized.add(payment);
          continue;
        }
        if (payment is Map) {
          try {
            normalized.add(payment.cast<String, dynamic>());
          } catch (_) {
            final converted = <String, dynamic>{};
            payment.forEach((key, value) {
              converted[key.toString()] = value;
            });
            normalized.add(converted);
          }
          continue;
        }
        normalized.add(_createDefaultPaymentEntry(''));
      }
      plot['payments'] = normalized;
      return normalized;
    }

    final empty = <Map<String, dynamic>>[];
    plot['payments'] = empty;
    return empty;
  }

  double _sumNumericTokens(String text) {
    final matches = RegExp(r'[-+]?\d[\d,]*(?:\.\d+)?').allMatches(text);
    if (matches.isEmpty) return 0.0;
    var total = 0.0;
    for (final match in matches) {
      final token = (match.group(0) ?? '').replaceAll(',', '').trim();
      if (token.isEmpty) continue;
      total += double.tryParse(token) ?? 0.0;
    }
    return total;
  }

  Map<String, dynamic> _parseAmenityPaymentStorageValue(dynamic rawValue) {
    final raw = (rawValue ?? '').toString().trim();
    if (raw.isEmpty) {
      return <String, dynamic>{'methods': '', 'amount': 0.0};
    }

    final delimiterIndex = raw.indexOf('|');
    if (delimiterIndex >= 0) {
      final methods = raw.substring(0, delimiterIndex).trim();
      final amountPart = raw.substring(delimiterIndex + 1).trim();
      final amount = _sumNumericTokens(amountPart);
      return <String, dynamic>{
        'methods': methods,
        'amount': amount,
      };
    }

    final amount = _sumNumericTokens(raw);
    if (amount <= 0) {
      return <String, dynamic>{'methods': raw, 'amount': 0.0};
    }

    final methods = raw
        .replaceAll(RegExp(r'₹?\s*[-+]?\d[\d,]*(?:\.\d+)?'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[-,:;|]+|[-,:;|]+$'), '')
        .trim();
    return <String, dynamic>{
      'methods': methods,
      'amount': amount,
    };
  }

  String _buildAmenityPaymentStorageValue({
    required String methodsText,
    required double totalPaidAmount,
  }) {
    const epsilon = 0.01;
    final methods = methodsText.trim();
    final hasAmount = totalPaidAmount > epsilon;

    if (!hasAmount && methods.isEmpty) {
      return '';
    }
    if (!hasAmount) {
      return methods;
    }

    final amountDisplay = _formatAmountNoTrailingZeros(
      _formatWithFixedDecimals(totalPaidAmount, 2),
    );
    if (methods.isEmpty) {
      return '₹ $amountDisplay';
    }
    return '$methods | ₹ $amountDisplay';
  }

  double _resolveAmenityPaidAmount(Map<String, dynamic> area) {
    final explicit = _parseMoneyLikeValue(
      area['paymentAmount'] ?? area['payment_amount'],
    );
    if (explicit > 0) return explicit;
    final parsed = _parseAmenityPaymentStorageValue(area['payment']);
    return (parsed['amount'] as double?) ?? 0.0;
  }

  List<Map<String, dynamic>> _buildAmenityPaymentsFromText(String paymentText) {
    final parsed = _parseAmenityPaymentStorageValue(paymentText);
    final methodsText = (parsed['methods'] ?? '').toString().trim();
    final totalAmount = (parsed['amount'] as double?) ?? 0.0;
    final methods = methodsText
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (methods.isEmpty) {
      if (totalAmount <= 0) return <Map<String, dynamic>>[];
      final entry = _createDefaultPaymentEntry('');
      entry['paymentAmount'] = _formatWithFixedDecimals(totalAmount, 2);
      return <Map<String, dynamic>>[entry];
    }
    final entries = methods
        .map((method) => _createDefaultPaymentEntry(method))
        .toList(growable: false);
    if (totalAmount > 0) {
      entries.first['paymentAmount'] = _formatWithFixedDecimals(totalAmount, 2);
    }
    return entries;
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
      _buyerNameFieldEpoch.remove(key);

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

  void _captureEditDialogSnapshot(int layoutIndex, int plotIndex) {
    if (layoutIndex < 0 || layoutIndex >= _layouts.length) {
      _clearEditDialogSnapshot();
      return;
    }
    final plots = _layouts[layoutIndex]['plots'];
    if (plots is! List || plotIndex < 0 || plotIndex >= plots.length) {
      _clearEditDialogSnapshot();
      return;
    }
    final plot = plots[plotIndex];
    if (plot is! Map) {
      _clearEditDialogSnapshot();
      return;
    }
    final cloned = _deepCloneValue(plot);
    if (cloned is Map<String, dynamic>) {
      _editDialogOriginalPlotSnapshot = cloned;
    } else if (cloned is Map) {
      _editDialogOriginalPlotSnapshot =
          cloned.map((k, v) => MapEntry(k.toString(), v));
    } else {
      _clearEditDialogSnapshot();
      return;
    }
    _editDialogOriginalLayoutIndex = layoutIndex;
    _editDialogOriginalPlotIndex = plotIndex;
  }

  void _restoreEditDialogSnapshotIfNeeded() {
    if (_editDialogOriginalPlotSnapshot == null ||
        _editDialogOriginalLayoutIndex == null ||
        _editDialogOriginalPlotIndex == null) {
      return;
    }
    final layoutIndex = _editDialogOriginalLayoutIndex!;
    final plotIndex = _editDialogOriginalPlotIndex!;
    if (layoutIndex < 0 || layoutIndex >= _layouts.length) return;
    final plots = _layouts[layoutIndex]['plots'];
    if (plots is! List || plotIndex < 0 || plotIndex >= plots.length) return;
    final restoredRaw = _deepCloneValue(_editDialogOriginalPlotSnapshot!);
    final targetPlot = plots[plotIndex];
    if (targetPlot is Map && restoredRaw is Map) {
      targetPlot.clear();
      for (final entry in restoredRaw.entries) {
        targetPlot[entry.key.toString()] = entry.value;
      }
      return;
    }
    plots[plotIndex] = restoredRaw;
  }

  void _clearEditDialogSnapshot() {
    _editDialogOriginalPlotSnapshot = null;
    _editDialogOriginalLayoutIndex = null;
    _editDialogOriginalPlotIndex = null;
  }

  Future<void> _discardCurrentEditDialogChanges() async {
    if (_editingLayoutIndex == null || _editingPlotIndex == null) return;
    setState(() {
      _restoreEditDialogSnapshotIfNeeded();
      _closeCurrentEditDialog();
      _rebuildAllPlotsFromLayouts(reason: 'edit_dialog_discard');
    });
    await _saveLayoutsData(immediate: true);
  }

  void _closeCurrentEditDialog() {
    final layoutIndex = _editingLayoutIndex;
    final plotIndex = _editingPlotIndex;
    if (layoutIndex != null && plotIndex != null) {
      _disposeDialogControllersForLayoutPlot(layoutIndex, plotIndex);
    }
    _removeAmenityEditTempLayoutIfNeeded();
    _editingLayoutIndex = null;
    _editingPlotIndex = null;
    _editingStatus = null;
    _isStatusDropdownOpen = false;
    _isPaymentMethodDropdownOpen = false;
    _isAgentDropdownOpen = false;
    _currentPaymentIndex = 0;
    _clearEditDialogSnapshot();
    _notifyEditDialogVisibilityChanged(false);
  }

  void _scheduleInvalidEditDialogReset() {
    if (_invalidEditDialogResetScheduled) return;
    _invalidEditDialogResetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _invalidEditDialogResetScheduled = false;
      if (!mounted) return;
      if (_editingLayoutIndex == null && _editingPlotIndex == null) return;
      setState(() {
        _closeCurrentEditDialog();
      });
    });
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
    plot['agent'] = _sanitizeAssignedAgentName(
      (plot['agent'] as String? ?? ''),
    );
    // Always recreate dialog field controllers from current row values.
    _disposeDialogControllersForLayoutPlot(layoutIndex, plotIndex);
    _captureEditDialogSnapshot(layoutIndex, plotIndex);

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
    _notifyEditDialogVisibilityChanged(true);
  }

  void _openAmenityEditDialog(int amenityIndex) {
    if (amenityIndex < 0 || amenityIndex >= _amenityAreas.length) return;

    final amenityArea = _amenityAreas[amenityIndex];
    final name = (amenityArea['name'] ?? '').toString().trim();
    final areaText = (amenityArea['area'] ?? '0').toString();
    final status = _parsePlotStatus(amenityArea['status']);
    final salePrice = (amenityArea['salePrice'] ?? '').toString();
    final buyerName = (amenityArea['buyerName'] ?? '').toString();
    final buyerContactNumber =
        (amenityArea['buyerContactNumber'] ?? '').toString();
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
          'buyerContactNumber': buyerContactNumber,
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

    final selectedStatus = _parsePlotStatus(editedPlot['status']);
    final rawSalePriceValue = _parseMoneyLikeValue(editedPlot['salePrice']);
    final rawSalePriceText = rawSalePriceValue > 0
        ? _formatWithFixedDecimals(rawSalePriceValue, 2)
        : '';
    final areaSqft = _parseMoneyLikeValue(amenityRow['area']);
    final rawSaleValue = areaSqft * rawSalePriceValue;
    final rawSaleValueText =
        rawSaleValue > 0 ? _formatWithFixedDecimals(rawSaleValue, 2) : '';
    final rawBuyerName = (editedPlot['buyerName'] ?? '').toString().trim();
    final rawBuyerContactNumber =
        (editedPlot['buyerContactNumber'] ?? '').toString().trim();
    final rawAgentName = (editedPlot['agent'] ?? '').toString().trim();
    final rawSaleDate = (editedPlot['saleDate'] ?? '').toString().trim();
    final payments = editedPlot['payments'] as List<dynamic>? ?? const [];
    final paymentMethods = <String>[];
    var totalPaidAmount = 0.0;
    for (final payment in payments) {
      if (payment is! Map<String, dynamic>) continue;
      final method = (payment['paymentMethod'] ?? '').toString().trim();
      if (method.isNotEmpty && !paymentMethods.contains(method)) {
        paymentMethods.add(method);
      }
      totalPaidAmount += _parseMoneyLikeValue(payment['paymentAmount']);
    }
    final paymentMethodsText = paymentMethods.join(', ');
    final rawPaymentStorageValue = _buildAmenityPaymentStorageValue(
      methodsText: paymentMethodsText,
      totalPaidAmount: totalPaidAmount,
    );
    final effectiveStatus = _resolveAutoStatusForPlot(<String, dynamic>{
      'status': selectedStatus,
      'area': amenityRow['area'],
      'salePrice': rawSalePriceText,
      'payments': payments,
    });
    final shouldClearSaleData = effectiveStatus == PlotStatus.available;
    final salePriceValue = shouldClearSaleData ? 0.0 : rawSalePriceValue;
    final salePriceText = shouldClearSaleData ? '' : rawSalePriceText;
    final saleValue = shouldClearSaleData ? 0.0 : rawSaleValue;
    final saleValueText = shouldClearSaleData ? '' : rawSaleValueText;
    final buyerName = shouldClearSaleData ? '' : rawBuyerName;
    final buyerContactNumber = shouldClearSaleData ? '' : rawBuyerContactNumber;
    final agentName = shouldClearSaleData ? '' : rawAgentName;
    final saleDate = shouldClearSaleData ? '' : rawSaleDate;
    final paymentStorageValue =
        shouldClearSaleData ? '' : rawPaymentStorageValue;
    if (shouldClearSaleData) {
      totalPaidAmount = 0.0;
    }

    setState(() {
      amenityRow['status'] = effectiveStatus;
      amenityRow['salePrice'] = salePriceText;
      amenityRow['saleValue'] = saleValueText;
      amenityRow['buyerName'] = buyerName;
      amenityRow['buyerContactNumber'] = buyerContactNumber;
      amenityRow['agent'] = agentName;
      amenityRow['saleDate'] = saleDate;
      amenityRow['payment'] = paymentStorageValue;
      amenityRow['paymentAmount'] = totalPaidAmount > 0
          ? _formatWithFixedDecimals(totalPaidAmount, 2)
          : '';
      _closeCurrentEditDialog();
    });

    final amenityId = (amenityRow['id'] ?? '').toString().trim();
    final projectId = widget.projectId?.trim() ?? '';
    _markUnsaved();
    _setSaveStatus(ProjectSaveStatusType.saving);
    // Save a dedicated status override so the status survives stale DB reads.
    if (projectId.isNotEmpty) {
      await _saveAmenityStatusOverride(
        projectId: projectId,
        amenityId: amenityId,
        amenityName: amenityRow['name'],
        status: _plotStatusToDatabaseValue(effectiveStatus),
      );
    }
    await _persistAmenitySnapshotFromCurrentState();
    await _markLocalEditTimestamp();

    ProjectSaveStatusType? localAmenityPersistenceStatus;
    if (projectId.isNotEmpty) {
      try {
        await _persistAmenityAreasToProjectStorage(projectId: projectId);
      } on ProjectSaveQueuedForSyncException {
        localAmenityPersistenceStatus = ProjectSaveStatusType.queuedOffline;
      } catch (e) {
        print('Error persisting amenity edits to project storage: $e');
        localAmenityPersistenceStatus = _isLikelyNetworkError(e)
            ? ProjectSaveStatusType.queuedOffline
            : ProjectSaveStatusType.connectionLost;
      }
    }

    if (amenityId.isEmpty || projectId.isEmpty) {
      if (localAmenityPersistenceStatus != null) {
        _setSaveStatus(localAmenityPersistenceStatus);
      } else {
        _markLocalSaveCompleted();
      }
      return;
    }

    final queueEntry = <String, dynamic>{
      'amenityId': amenityId,
      'name': (amenityRow['name'] ?? '').toString().trim(),
      'area': (amenityRow['area'] ?? '0').toString(),
      'allInCost': (amenityRow['allInCost'] ?? amenityRow['all_in_cost'] ?? '')
          .toString(),
      'status': _plotStatusToDatabaseValue(effectiveStatus),
      'salePrice': salePriceValue > 0 ? salePriceValue : null,
      'saleValue': saleValue > 0 ? saleValue : null,
      'buyerName': buyerName.isEmpty ? null : buyerName,
      'buyerContactNumber':
          buyerContactNumber.isEmpty ? null : buyerContactNumber,
      'payment': paymentStorageValue.isEmpty ? null : paymentStorageValue,
      'paymentAmount': totalPaidAmount > 0 ? totalPaidAmount : null,
      'agentName': agentName.isEmpty ? null : agentName,
      'saleDate': _formatDateForDatabase(saleDate),
      'queuedAtMs': DateTime.now().millisecondsSinceEpoch,
      'attempts': 0,
      'lastError': '',
    };

    try {
      await _upsertPendingAmenitySyncQueueEntry(
        projectId: projectId,
        entry: queueEntry,
      );
      final queueDrained = await _flushPendingAmenitySyncQueue(
        projectId: projectId,
      );
      if (queueDrained) {
        if (localAmenityPersistenceStatus ==
            ProjectSaveStatusType.connectionLost) {
          _setSaveStatus(ProjectSaveStatusType.connectionLost);
        } else {
          _markLocalSaveCompleted();
        }
      } else {
        _setSaveStatus(ProjectSaveStatusType.queuedOffline);
      }
    } catch (e) {
      print('Error saving amenity area edits: $e');
      _setSaveStatus(
        _isLikelyNetworkError(e)
            ? ProjectSaveStatusType.queuedOffline
            : ProjectSaveStatusType.connectionLost,
      );
    }
  }

  Future<List<Map<String, dynamic>>> _fetchLayoutsForPlotStatus(
    String projectId,
  ) async {
    try {
      final rows = await _supabase
          .from('layouts')
          .select(
              'id, name, layout_image_name, layout_image_path, layout_image_doc_id, layout_image_extension')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);
      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      print(
          'PlotStatusPage: Layout extended select failed, using fallback: $e');
      final rows = await _supabase
          .from('layouts')
          .select('id, name')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);
      return List<Map<String, dynamic>>.from(rows).map((row) {
        return <String, dynamic>{
          ...row,
          'layout_image_name': '',
          'layout_image_path': '',
          'layout_image_doc_id': '',
          'layout_image_extension': '',
        };
      }).toList(growable: false);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchPlotsForLayouts(
    List<String> layoutIds,
  ) async {
    if (layoutIds.isEmpty) return <Map<String, dynamic>>[];
    Future<List<Map<String, dynamic>>> run(String selectClause) async {
      final rows = await _supabase
          .from('plots')
          .select(selectClause)
          .inFilter('layout_id', layoutIds)
          .order('created_at', ascending: true)
          .order('id', ascending: true);
      return List<Map<String, dynamic>>.from(rows);
    }

    const baseSelectClause =
        'id, layout_id, plot_number, area, all_in_cost_per_sqft, total_plot_cost, status, sale_price, buyer_name, sale_date, agent_name, payments';
    final contactColumn = await _resolvePlotsBuyerContactColumnName();
    final resolvedSelectClause = contactColumn == null
        ? baseSelectClause
        : '$baseSelectClause, $contactColumn';

    try {
      return await run(resolvedSelectClause);
    } catch (e) {
      print(
          'PlotStatusPage: Plot select failed for "$resolvedSelectClause", using fallback: $e');
      return await run(baseSelectClause);
    }
  }

  void _applyLoadedPlotDataToState({
    required List<Map<String, dynamic>> sourceLayouts,
    required List<Map<String, dynamic>> sourceAmenityAreas,
    required List<Map<String, dynamic>> agents,
    required String amenityLayoutImageName,
    required String amenityLayoutImagePath,
    required String amenityLayoutImageDocId,
    required String amenityLayoutImageExtension,
  }) {
    final convertedLayouts = _convertLayoutsData(sourceLayouts);
    final convertedAmenityAreas = _convertAmenityAreasData(sourceAmenityAreas);
    final mergedAmenityAreas = _mergeAmenityDisplayRowsKeepDetails(
      incomingRows: convertedAmenityAreas,
      existingRows: _amenityAreas,
    );

    void applyMutation() {
      _storedAgents = agents;
      _layouts = convertedLayouts;
      _amenityAreas = mergedAmenityAreas;
      _amenityLayoutImageName = amenityLayoutImageName;
      _amenityLayoutImagePath = amenityLayoutImagePath;
      _amenityLayoutImageDocId = amenityLayoutImageDocId;
      _amenityLayoutImageExtension = amenityLayoutImageExtension;
      _allPlots = [];

      // Populate _allPlots from layouts for filtering/search.
      for (var layoutIndex = 0; layoutIndex < _layouts.length; layoutIndex++) {
        final layout = _layouts[layoutIndex];
        final layoutName = layout['name'] as String? ?? '';
        final plots = _coerceMapList(layout['plots']);
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

      if (!_hasAmenityAreaData &&
          _activeContentTab == PlotStatusContentTab.amenityArea) {
        _activeContentTab = PlotStatusContentTab.site;
        unawaited(_persistActiveContentTab(PlotStatusContentTab.site));
      }

      _clearInvalidAssignedAgentsFromLayouts();
    }

    if (mounted) {
      setState(applyMutation);
    } else {
      applyMutation();
    }

    if (!_hasUnsavedChanges) {
      _captureRemoteLayoutSignatures(convertedLayouts);
    }
  }

  Future<void> _loadPlotData({
    required int loadGeneration,
    bool suppressEarlyLoadingRelease = false,
  }) async {
    if (loadGeneration != _plotDataLoadGeneration) return;
    if (!widget.isActive) return;
    _areaUnit = await AreaUnitService.getAreaUnit(widget.projectId);
    if (loadGeneration != _plotDataLoadGeneration || !widget.isActive) return;
    List<Map<String, dynamic>> sourceLayouts = widget.layouts ?? [];
    List<Map<String, dynamic>> sourceAmenityAreas = [];
    List<Map<String, dynamic>> agents = [];
    Map<String, dynamic>? localProjectData;
    final normalizedProjectId = widget.projectId?.trim() ?? '';
    String amenityLayoutImageName = _amenityLayoutImageName;
    String amenityLayoutImagePath = _amenityLayoutImagePath;
    String amenityLayoutImageDocId = _amenityLayoutImageDocId;
    String amenityLayoutImageExtension = _amenityLayoutImageExtension;

    if (normalizedProjectId.isNotEmpty) {
      try {
        await ProjectStorageService.reconcileDocumentBackedMetadata(
          normalizedProjectId,
        );
      } catch (error) {
        print(
            'PlotStatusPage: document metadata reconciliation skipped for $normalizedProjectId: $error');
      }
    }

    print(
        '🔵 _loadPlotData ENTRY: widget.layouts=${widget.layouts?.length ?? "null"}, widget.projectId=${widget.projectId}');

    // Local-first seed: always read local layouts/snapshots first so page-to-page
    // navigation remains instant even on poor network.
    final localLayoutsSeed = await LayoutStorageService.loadLayoutsData(
      projectKey: widget.projectId,
    );
    if (localLayoutsSeed.isNotEmpty) {
      sourceLayouts = localLayoutsSeed;
      print(
          '📥 PlotStatusPage local-first seed: ${localLayoutsSeed.length} layouts');
    }
    if (normalizedProjectId.isNotEmpty) {
      final localAmenitySnapshot = await _loadAmenitySnapshotRows(
        projectId: normalizedProjectId,
      );
      if (localAmenitySnapshot.isNotEmpty) {
        sourceAmenityAreas = localAmenitySnapshot;
        print(
            '📥 PlotStatusPage local-first amenity snapshot: ${localAmenitySnapshot.length} rows');
      }
    }
    if (normalizedProjectId.isNotEmpty) {
      localProjectData = await ProjectStorageService.getLocalSnapshotForProject(
        normalizedProjectId,
      );
      if (localProjectData != null) {
        if (sourceLayouts.isEmpty) {
          final localSnapshotLayouts =
              _toDynamicMapList(localProjectData['layouts']);
          if (localSnapshotLayouts.isNotEmpty) {
            sourceLayouts = localSnapshotLayouts;
            print(
                '📥 PlotStatusPage local snapshot seed: ${localSnapshotLayouts.length} layouts');
          }
        }
        if (sourceAmenityAreas.isEmpty) {
          final localAmenityAreas =
              _toDynamicMapList(localProjectData['amenityAreas']);
          if (localAmenityAreas.isNotEmpty) {
            sourceAmenityAreas = localAmenityAreas;
            print(
                '📥 PlotStatusPage local snapshot amenity seed: ${localAmenityAreas.length} rows');
          }
        }
        amenityLayoutImageName = (localProjectData['amenityLayoutImageName'] ??
                localProjectData['amenity_layout_image_name'] ??
                amenityLayoutImageName)
            .toString()
            .trim();
        amenityLayoutImagePath = (localProjectData['amenityLayoutImagePath'] ??
                localProjectData['amenity_layout_image_path'] ??
                amenityLayoutImagePath)
            .toString()
            .trim();
        amenityLayoutImageDocId =
            (localProjectData['amenityLayoutImageDocId'] ??
                    localProjectData['amenity_layout_image_doc_id'] ??
                    amenityLayoutImageDocId)
                .toString()
                .trim();
        amenityLayoutImageExtension =
            (localProjectData['amenityLayoutImageExtension'] ??
                    localProjectData['amenity_layout_image_extension'] ??
                    amenityLayoutImageExtension)
                .toString()
                .trim();
      }
    }
    final knownDocumentIds = <String>{};
    final knownDocumentPaths = <String>{};
    var documentsLookupSucceeded = false;
    if (normalizedProjectId.isNotEmpty) {
      try {
        final docs = await _supabase
            .from('documents')
            .select('id,file_url')
            .eq('project_id', normalizedProjectId)
            .eq('type', 'file')
            .limit(5000);
        if (docs is List) {
          for (final raw in docs) {
            if (raw is! Map) continue;
            final row = Map<String, dynamic>.from(raw);
            final docId = (row['id'] ?? '').toString().trim();
            final path = _resolveDocumentStoragePath(
              (row['file_url'] ?? '').toString(),
            );
            if (docId.isNotEmpty) {
              knownDocumentIds.add(docId);
            }
            if (path.isNotEmpty) {
              knownDocumentPaths.add(path);
            }
          }
        }
        documentsLookupSucceeded = true;
      } catch (_) {
        documentsLookupSucceeded = false;
      }
    }

    bool shouldClearDocumentMeta({
      required String docId,
      required String storagePath,
    }) {
      if (!documentsLookupSucceeded) return false;
      final normalizedDocId = docId.trim();
      final normalizedPath = _resolveDocumentStoragePath(storagePath);
      if (normalizedDocId.isEmpty && normalizedPath.isEmpty) return false;
      final missingDoc = normalizedDocId.isNotEmpty &&
          !knownDocumentIds.contains(normalizedDocId);
      final missingPath = normalizedPath.isNotEmpty &&
          !knownDocumentPaths.contains(normalizedPath);
      return missingDoc || missingPath;
    }

    for (final rawLayout in sourceLayouts) {
      if (rawLayout is! Map) continue;
      final layout = Map<String, dynamic>.from(rawLayout);
      final layoutDocId =
          (layout['layoutImageDocId'] ?? layout['layout_image_doc_id'] ?? '')
              .toString();
      final layoutPath =
          (layout['layoutImagePath'] ?? layout['layout_image_path'] ?? '')
              .toString();
      final shouldClear = shouldClearDocumentMeta(
        docId: layoutDocId,
        storagePath: layoutPath,
      );
      if (!shouldClear) continue;
      layout['layoutImageName'] = '';
      layout['layoutImagePath'] = '';
      layout['layoutImageDocId'] = '';
      layout['layoutImageExtension'] = '';
      layout['layout_image_name'] = '';
      layout['layout_image_path'] = '';
      layout['layout_image_doc_id'] = '';
      layout['layout_image_extension'] = '';
      rawLayout
        ..['layoutImageName'] = ''
        ..['layoutImagePath'] = ''
        ..['layoutImageDocId'] = ''
        ..['layoutImageExtension'] = ''
        ..['layout_image_name'] = ''
        ..['layout_image_path'] = ''
        ..['layout_image_doc_id'] = ''
        ..['layout_image_extension'] = '';
    }

    if (shouldClearDocumentMeta(
      docId: amenityLayoutImageDocId,
      storagePath: amenityLayoutImagePath,
    )) {
      amenityLayoutImageName = '';
      amenityLayoutImagePath = '';
      amenityLayoutImageDocId = '';
      amenityLayoutImageExtension = '';
    }
    final hasLocalLayoutsSeed = sourceLayouts.isNotEmpty;
    final hasLocalAmenitySeed = sourceAmenityAreas.isNotEmpty;

    // Paint local data immediately so navigation feels instant.
    // For explicit forced refresh, keep full-page skeleton visible until the
    // refresh cycle completes, so skip this early release path.
    if ((hasLocalLayoutsSeed || hasLocalAmenitySeed) &&
        !suppressEarlyLoadingRelease) {
      if (agents.isEmpty) {
        agents = await LayoutStorageService.loadAgentsData();
      }
      if (normalizedProjectId.isNotEmpty) {
        final pendingAmenityQueue = await _loadPendingAmenitySyncQueue(
          projectId: normalizedProjectId,
        );
        if (pendingAmenityQueue.isNotEmpty) {
          sourceAmenityAreas = _applyPendingAmenitySyncQueueToRows(
            sourceAmenityAreas,
            pendingAmenityQueue,
          );
        }
        // Apply dedicated status overrides for the early paint too.
        if (normalizedProjectId.isNotEmpty) {
          final statusOverrides = await _loadAmenityStatusOverrides(
            projectId: normalizedProjectId,
          );
          if (statusOverrides.isNotEmpty) {
            sourceAmenityAreas = _applyAmenityStatusOverrides(
              sourceAmenityAreas,
              statusOverrides,
            );
          }
        }
      }

      if (loadGeneration != _plotDataLoadGeneration) return;
      _applyLoadedPlotDataToState(
        sourceLayouts: sourceLayouts,
        sourceAmenityAreas: sourceAmenityAreas,
        agents: agents,
        amenityLayoutImageName: amenityLayoutImageName,
        amenityLayoutImagePath: amenityLayoutImagePath,
        amenityLayoutImageDocId: amenityLayoutImageDocId,
        amenityLayoutImageExtension: amenityLayoutImageExtension,
      );
      if (loadGeneration == _plotDataLoadGeneration && _isLoading) {
        if (mounted) {
          setState(() => _isLoading = false);
        } else {
          _isLoading = false;
        }
        _notifyLoadingState(false);
      }
    }

    // If projectId is available, load from database first
    if (widget.projectId != null && widget.projectId!.isNotEmpty) {
      try {
        print(
            'PlotStatusPage: Loading data from database for projectId=${widget.projectId}');

        if (!_projectAmenityMetaColumnsMissing) {
          try {
            final projectMeta = await _supabase
                .from('projects')
                .select(
                    'amenity_layout_image_name, amenity_layout_image_path, amenity_layout_image_doc_id, amenity_layout_image_extension')
                .eq('id', widget.projectId!)
                .maybeSingle();
            if (projectMeta != null) {
              amenityLayoutImageName =
                  (projectMeta['amenity_layout_image_name'] ?? '')
                      .toString()
                      .trim();
              amenityLayoutImagePath =
                  (projectMeta['amenity_layout_image_path'] ?? '')
                      .toString()
                      .trim();
              amenityLayoutImageDocId =
                  (projectMeta['amenity_layout_image_doc_id'] ?? '')
                      .toString()
                      .trim();
              amenityLayoutImageExtension =
                  (projectMeta['amenity_layout_image_extension'] ?? '')
                      .toString()
                      .trim();
            }
          } catch (e) {
            final message = e.toString();
            final missingColumn = message.contains('42703') &&
                message.contains('amenity_layout_image_name');
            if (missingColumn) {
              _projectAmenityMetaColumnsMissing = true;
              print(
                  'PlotStatusPage: Skipping projects amenity image meta query (columns not present).');
            } else {
              print(
                  'PlotStatusPage: Unable to load amenity layout image meta: $e');
            }
          }
        }

        // Load layouts from database
        final layouts = await _fetchLayoutsForPlotStatus(widget.projectId!);

        final existingDocumentIds = <String>{};
        final existingDocumentPaths = <String>{};
        final staleLayoutImageMetaIds = <String>{};
        try {
          final docs = await _supabase
              .from('documents')
              .select('id,file_url')
              .eq('project_id', widget.projectId!)
              .eq('type', 'file')
              .limit(3000);
          if (docs is List) {
            for (final raw in docs) {
              if (raw is! Map) continue;
              final row = Map<String, dynamic>.from(raw);
              final docId = (row['id'] ?? '').toString().trim();
              final docPath = _resolveDocumentStoragePath(
                (row['file_url'] ?? '').toString(),
              );
              if (docId.isNotEmpty) {
                existingDocumentIds.add(docId);
              }
              if (docPath.isNotEmpty) {
                existingDocumentPaths.add(docPath);
              }
            }
          }
        } catch (_) {}

        print('📥 LOADED LAYOUTS FROM DB: ${layouts.length} layouts');
        for (var i = 0; i < layouts.length; i++) {
          print(
              '   Layout $i: id=${layouts[i]['id']}, name=${layouts[i]['name']}');
        }

        final layoutsData = <Map<String, dynamic>>[];
        var amenityRowsLoadedFromDb = false;
        // Load the local snapshot BEFORE the DB fetch so we can protect
        // locally-saved statuses from being overwritten by a stale DB read.
        final preLoadSnapshot = normalizedProjectId.isNotEmpty
            ? await _loadAmenitySnapshotRows(projectId: normalizedProjectId)
            : <Map<String, dynamic>>[];

        try {
          final amenityAreasData = await _supabase
              .from('amenity_areas')
              .select()
              .eq('project_id', widget.projectId!)
              .order('sort_order', ascending: true)
              .order('created_at', ascending: true)
              .order('id', ascending: true);
          final dbAmenityAreas = amenityAreasData.cast<Map<String, dynamic>>();
          // Start with DB rows for structure/ordering, then immediately
          // overlay the local snapshot so locally-saved statuses are never
          // lost due to a stale DB read.
          sourceAmenityAreas = dbAmenityAreas;
          amenityRowsLoadedFromDb = true;
          if (preLoadSnapshot.isNotEmpty) {
            sourceAmenityAreas = _mergeSnapshotIntoAmenityRows(
              dbRows: sourceAmenityAreas,
              snapshotRows: preLoadSnapshot,
            );
          }
        } catch (e) {
          if (!hasLocalAmenitySeed) {
            sourceAmenityAreas = [];
          }
          print('PlotStatusPage: Unable to load amenity_areas: $e');
        }

        if (normalizedProjectId.isNotEmpty) {
          if (sourceAmenityAreas.isEmpty && !amenityRowsLoadedFromDb) {
            if (preLoadSnapshot.isNotEmpty) {
              sourceAmenityAreas = preLoadSnapshot;
              print(
                  'PlotStatusPage: Restored amenity areas from local snapshot (${preLoadSnapshot.length} rows)');
            }
          }

          final pendingAmenityQueue = await _loadPendingAmenitySyncQueue(
            projectId: normalizedProjectId,
          );
          if (pendingAmenityQueue.isNotEmpty) {
            sourceAmenityAreas = _applyPendingAmenitySyncQueueToRows(
              sourceAmenityAreas,
              pendingAmenityQueue,
            );
            print(
                'PlotStatusPage: Applied pending amenity sync queue (${pendingAmenityQueue.length} rows)');
          }

          // Apply dedicated status overrides — the most reliable layer.
          // These are written on every user edit and never cleared by DB loads.
          final statusOverrides = await _loadAmenityStatusOverrides(
            projectId: normalizedProjectId,
          );
          if (statusOverrides.isNotEmpty) {
            sourceAmenityAreas = _applyAmenityStatusOverrides(
              sourceAmenityAreas,
              statusOverrides,
            );
          }

          if (preLoadSnapshot.isNotEmpty && sourceAmenityAreas.isNotEmpty) {
            sourceAmenityAreas = _mergeAmenitySalesDetailsIntoRows(
              baseRows: sourceAmenityAreas,
              detailRows: preLoadSnapshot,
            );
          }

          // If DB/status layers only carry status but local project storage has
          // richer amenity sale columns, merge those details back in.
          final localAmenityAreasFromProject =
              _toDynamicMapList(localProjectData?['amenityAreas']);
          if (localAmenityAreasFromProject.isNotEmpty) {
            if (sourceAmenityAreas.isEmpty) {
              sourceAmenityAreas = localAmenityAreasFromProject;
            } else {
              sourceAmenityAreas = _mergeAmenitySalesDetailsIntoRows(
                baseRows: sourceAmenityAreas,
                detailRows: localAmenityAreasFromProject,
              );
              print(
                  'PlotStatusPage: Backfilled amenity sale columns from local project storage');
            }
          }

          var snapshotRowsToPersist = sourceAmenityAreas;
          if (snapshotRowsToPersist.isEmpty && preLoadSnapshot.isNotEmpty) {
            snapshotRowsToPersist = preLoadSnapshot;
          }
          if (snapshotRowsToPersist.isEmpty &&
              localAmenityAreasFromProject.isNotEmpty) {
            snapshotRowsToPersist = localAmenityAreasFromProject;
          }
          if (snapshotRowsToPersist.isNotEmpty && preLoadSnapshot.isNotEmpty) {
            snapshotRowsToPersist = _mergeAmenitySalesDetailsIntoRows(
              baseRows: snapshotRowsToPersist,
              detailRows: preLoadSnapshot,
            );
          }
          if (snapshotRowsToPersist.isNotEmpty &&
              localAmenityAreasFromProject.isNotEmpty) {
            snapshotRowsToPersist = _mergeAmenitySalesDetailsIntoRows(
              baseRows: snapshotRowsToPersist,
              detailRows: localAmenityAreasFromProject,
            );
          }
          if (_shouldPersistAmenitySnapshotAfterLoad(
            previousSnapshotRows: preLoadSnapshot,
            nextSnapshotRows: snapshotRowsToPersist,
          )) {
            await _persistAmenitySnapshotRows(
              projectId: normalizedProjectId,
              rows: snapshotRowsToPersist,
            );
          }
        }

        if (layouts.isNotEmpty) {
          final layoutIds = layouts
              .map((layout) => (layout['id'] ?? '').toString())
              .where((id) => id.isNotEmpty)
              .toList(growable: false);

          var allPlots = <Map<String, dynamic>>[];
          if (layoutIds.isNotEmpty) {
            for (var attempt = 0; attempt < 3; attempt++) {
              allPlots = await _fetchPlotsForLayouts(layoutIds);
              if (allPlots.isNotEmpty) break;
              if (attempt < 2) {
                await Future<void>.delayed(const Duration(milliseconds: 250));
              }
            }
          }

          final plotIds = allPlots
              .map((plot) => (plot['id'] ?? '').toString())
              .where((id) => id.isNotEmpty)
              .toList(growable: false);
          final plotPartnerRows = plotIds.isEmpty
              ? <Map<String, dynamic>>[]
              : List<Map<String, dynamic>>.from(
                  await _supabase
                      .from('plot_partners')
                      .select('plot_id, partner_name')
                      .inFilter('plot_id', plotIds),
                );

          final partnersByPlotId = <String, List<String>>{};
          for (final row in plotPartnerRows) {
            final plotId = (row['plot_id'] ?? '').toString();
            final partnerName = (row['partner_name'] ?? '').toString().trim();
            if (plotId.isEmpty || partnerName.isEmpty) continue;
            partnersByPlotId.putIfAbsent(plotId, () => <String>[]);
            partnersByPlotId[plotId]!.add(partnerName);
          }

          final plotsByLayoutId = <String, List<Map<String, dynamic>>>{};
          for (final plot in allPlots) {
            final layoutId = (plot['layout_id'] ?? '').toString();
            if (layoutId.isEmpty) continue;
            plotsByLayoutId.putIfAbsent(
                layoutId, () => <Map<String, dynamic>>[]);
            plotsByLayoutId[layoutId]!.add(plot);
          }

          for (final layout in layouts) {
            final layoutId = (layout['id'] ?? '').toString();
            final layoutImageNameRaw =
                (layout['layout_image_name'] ?? '').toString().trim();
            final layoutImagePathRaw =
                (layout['layout_image_path'] ?? '').toString().trim();
            final layoutImageDocIdRaw =
                (layout['layout_image_doc_id'] ?? '').toString().trim();
            final layoutImageExtensionRaw =
                (layout['layout_image_extension'] ?? '').toString().trim();
            final layoutImagePathResolved =
                _resolveDocumentStoragePath(layoutImagePathRaw);
            final hasDbImageMeta = layoutImageDocIdRaw.isNotEmpty ||
                layoutImagePathResolved.isNotEmpty;
            final dbImageMetaValid = !hasDbImageMeta ||
                (layoutImageDocIdRaw.isNotEmpty &&
                    existingDocumentIds.contains(layoutImageDocIdRaw)) ||
                (layoutImagePathResolved.isNotEmpty &&
                    existingDocumentPaths.contains(layoutImagePathResolved));
            if (!dbImageMetaValid && layoutId.isNotEmpty) {
              staleLayoutImageMetaIds.add(layoutId);
            }
            final layoutPlots =
                plotsByLayoutId[layoutId] ?? const <Map<String, dynamic>>[];
            final plotsData = layoutPlots.map((plot) {
              final plotId = (plot['id'] ?? '').toString();
              return {
                'id': plotId,
                'plotNumber': (plot['plot_number'] ?? '').toString(),
                'area': _formatWithFixedDecimals(plot['area'] ?? 0.0, 3),
                'purchaseRate': _formatWithFixedDecimals(
                    plot['all_in_cost_per_sqft'] ?? 0.0, 2),
                'totalPlotCost':
                    _formatWithFixedDecimals(plot['total_plot_cost'] ?? 0.0, 2),
                'status': _parsePlotStatus(plot['status']),
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
                'partners': List<String>.from(
                  partnersByPlotId[plotId] ?? const <String>[],
                ),
                'payments': (plot['payments'] as List<dynamic>?) ?? [],
              };
            }).toList(growable: false);

            layoutsData.add({
              'id': layoutId,
              'name': (layout['name'] ?? '').toString(),
              'layoutImageName': dbImageMetaValid ? layoutImageNameRaw : '',
              'layoutImagePath':
                  dbImageMetaValid ? layoutImagePathResolved : '',
              'layoutImageDocId': dbImageMetaValid ? layoutImageDocIdRaw : '',
              'layoutImageExtension':
                  dbImageMetaValid ? layoutImageExtensionRaw : '',
              'plots': plotsData,
            });
          }
        }

        if (staleLayoutImageMetaIds.isNotEmpty) {
          try {
            await _supabase
                .from('layouts')
                .update({
                  'layout_image_name': '',
                  'layout_image_path': '',
                  'layout_image_doc_id': '',
                  'layout_image_extension': '',
                })
                .eq('project_id', widget.projectId!)
                .inFilter(
                    'id', staleLayoutImageMetaIds.toList(growable: false));
          } catch (_) {}
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
          if (hasLocalLayoutsSeed && sourceLayouts.isNotEmpty) {
            print(
                '✅ Keeping local-first layouts (remote has ${layoutsData.length} layouts with plots)');
          } else {
            sourceLayouts = layoutsData;
            print(
                '✅ Using database layouts (has ${layoutsData.length} layouts with plots)');
          }
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
      List<Map<String, dynamic>> localLayouts =
          await LayoutStorageService.loadLayoutsData(
        projectKey: widget.projectId,
      );
      // Data Entry writes local layout snapshot asynchronously. When switching
      // pages immediately after edits, allow a short settle window so Plot
      // Status doesn't flash "No Layouts Added" before local data lands.
      final shouldWaitForRecentLocalWrite =
          widget.dataVersion > 0 && localLayouts.isEmpty;
      if (shouldWaitForRecentLocalWrite) {
        for (var attempt = 0; attempt < 8; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          localLayouts = await LayoutStorageService.loadLayoutsData(
            projectKey: widget.projectId,
          );
          if (localLayouts.isNotEmpty) {
            print(
                '📥 PlotStatusPage recovered local layouts after short wait (attempt ${attempt + 1})');
            break;
          }
        }
      }
      if (localLayouts.isNotEmpty) {
        sourceLayouts = localLayouts;
      } else if (_layouts.isNotEmpty) {
        // Avoid flashing "No layouts" on transient cross-client save windows.
        sourceLayouts = _layouts
            .map((layout) => <String, dynamic>{
                  ...layout,
                  'plots': ((layout['plots'] as List<dynamic>?) ?? const [])
                      .map((plot) => Map<String, dynamic>.from(plot as Map))
                      .toList(growable: false),
                })
            .toList(growable: false);
      }
      print('📥 Loaded from local storage: ${sourceLayouts.length} layouts');
    }

    // If this client has unsaved local edits newer than the last successful
    // remote save, keep showing local layouts so in-flight local changes are
    // not wiped during refresh. Clean sessions must prefer remote data.
    final projectId = widget.projectId?.trim();
    if (projectId != null && projectId.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final localEditMs =
            prefs.getInt('project_${projectId}_last_local_edit_ms') ?? 0;
        final remoteSaveMs =
            prefs.getInt('project_${projectId}_last_remote_save_ms') ?? 0;
        final hasPendingOfflineSaves =
            await ProjectStorageService.hasPendingOfflineSaves(
          projectId: projectId,
        );
        final hasPendingProjectCreate =
            await OfflineProjectSyncService.isPendingLocalProject(
          projectId: projectId,
          userId: _supabase.auth.currentUser?.id,
        );
        final hasPendingOfflineSync =
            hasPendingOfflineSaves || hasPendingProjectCreate;
        final shouldPreferLocalLayouts =
            hasPendingOfflineSync || localEditMs > remoteSaveMs;
        final localAmenityAreasForComparison =
            _toDynamicMapList(localProjectData?['amenityAreas']);
        final shouldPreferLocalAmenity = sourceAmenityAreas.isEmpty ||
            (_amenityRowsContainSaleColumnsData(
                    localAmenityAreasForComparison) &&
                !_amenityRowsContainSaleColumnsData(sourceAmenityAreas)) ||
            localAmenityAreasForComparison.isNotEmpty;
        if (shouldPreferLocalLayouts) {
          final localLayouts = await LayoutStorageService.loadLayoutsData(
            projectKey: widget.projectId,
          );
          if (localLayouts.isNotEmpty) {
            print(
                '📥 PlotStatusPage using newer local layouts (local=$localEditMs remote=$remoteSaveMs)');
            sourceLayouts = localLayouts;
          }
        }
        if (shouldPreferLocalAmenity) {
          localProjectData ??=
              await ProjectStorageService.fetchProjectDataById(projectId);
          final localAmenityAreas =
              _toDynamicMapList(localProjectData?['amenityAreas']);
          if (localAmenityAreas.isNotEmpty) {
            if (sourceAmenityAreas.isEmpty) {
              sourceAmenityAreas = localAmenityAreas;
            } else {
              sourceAmenityAreas = _mergeAmenitySalesDetailsIntoRows(
                baseRows: sourceAmenityAreas,
                detailRows: localAmenityAreas,
              );
            }
            print(
                '📥 PlotStatusPage using local amenity areas (${localAmenityAreas.length} rows)');
          }
        }
        final hasAmenityImageMeta = amenityLayoutImageName.isNotEmpty ||
            amenityLayoutImagePath.isNotEmpty ||
            amenityLayoutImageDocId.isNotEmpty;
        if (!hasAmenityImageMeta) {
          localProjectData ??=
              await ProjectStorageService.fetchProjectDataById(projectId);
          if (localProjectData != null) {
            amenityLayoutImageName =
                (localProjectData['amenityLayoutImageName'] ??
                        localProjectData['amenity_layout_image_name'] ??
                        '')
                    .toString()
                    .trim();
            amenityLayoutImagePath =
                (localProjectData['amenityLayoutImagePath'] ??
                        localProjectData['amenity_layout_image_path'] ??
                        '')
                    .toString()
                    .trim();
            amenityLayoutImageDocId =
                (localProjectData['amenityLayoutImageDocId'] ??
                        localProjectData['amenity_layout_image_doc_id'] ??
                        '')
                    .toString()
                    .trim();
            amenityLayoutImageExtension =
                (localProjectData['amenityLayoutImageExtension'] ??
                        localProjectData['amenity_layout_image_extension'] ??
                        '')
                    .toString()
                    .trim();
          }
        }
        if (sourceAmenityAreas.isNotEmpty) {
          final pendingAmenityQueue = await _loadPendingAmenitySyncQueue(
            projectId: projectId,
          );
          if (pendingAmenityQueue.isNotEmpty) {
            sourceAmenityAreas = _applyPendingAmenitySyncQueueToRows(
              sourceAmenityAreas,
              pendingAmenityQueue,
            );
          }
          final statusOverrides = await _loadAmenityStatusOverrides(
            projectId: projectId,
          );
          if (statusOverrides.isNotEmpty) {
            sourceAmenityAreas = _applyAmenityStatusOverrides(
              sourceAmenityAreas,
              statusOverrides,
            );
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

    if (loadGeneration != _plotDataLoadGeneration || !widget.isActive) return;
    _debugLogAmenityRows('pre_apply', sourceAmenityAreas);
    _applyLoadedPlotDataToState(
      sourceLayouts: sourceLayouts,
      sourceAmenityAreas: sourceAmenityAreas,
      agents: agents,
      amenityLayoutImageName: amenityLayoutImageName,
      amenityLayoutImagePath: amenityLayoutImagePath,
      amenityLayoutImageDocId: amenityLayoutImageDocId,
      amenityLayoutImageExtension: amenityLayoutImageExtension,
    );
    _cacheCurrentStateForSession(normalizedProjectId);
    print('PlotStatusPage: Loaded ${_allPlots.length} plots total');

    // Release page-level loading as soon as core rows are visible.
    if (!suppressEarlyLoadingRelease &&
        loadGeneration == _plotDataLoadGeneration) {
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
      } else {
        _isLoading = false;
      }
      _notifyLoadingState(false);
    }

    if (projectId != null && projectId.isNotEmpty) {
      // Metadata reconciliation is best-effort and should not delay render.
      unawaited(
        _syncAmenityLayoutImageFromDocumentsIfMissing(
          projectId: projectId,
        ).catchError((_) {}),
      );
    }

    // Defer controller initialization so first paint is not blocked.
    await Future<void>.delayed(Duration.zero);
    if (!mounted || !widget.isActive) return;
    _initializeControllersFromData();
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
    _buyerNameFieldEpoch.clear();

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

  Future<void> _saveLayoutsData({bool immediate = false}) async {
    if (_isEditingAmenityArea) {
      return;
    }
    _hasQueuedLayoutSave = true;
    _queuedLayoutSaveCompleter ??= Completer<void>();

    if (immediate || _isLayoutSaveInFlight) {
      _layoutSaveDebounceTimer?.cancel();
      unawaited(_drainQueuedLayoutSaves());
      return _queuedLayoutSaveCompleter!.future;
    }

    _layoutSaveDebounceTimer?.cancel();
    _layoutSaveDebounceTimer = Timer(_layoutSaveDebounceDelay, () {
      unawaited(_drainQueuedLayoutSaves());
    });
    return _queuedLayoutSaveCompleter!.future;
  }

  Future<void> _drainQueuedLayoutSaves() async {
    if (_isLayoutSaveInFlight) return;

    while (_hasQueuedLayoutSave) {
      _hasQueuedLayoutSave = false;
      _isLayoutSaveInFlight = true;
      try {
        await _saveLayoutsDataNow();
      } catch (e) {
        print('Error saving plot status layout queue: $e');
        _setSaveStatus(
          e is ProjectSaveQueuedForSyncException
              ? ProjectSaveStatusType.queuedOffline
              : ProjectSaveStatusType.connectionLost,
        );
      } finally {
        _isLayoutSaveInFlight = false;
      }
    }

    if (_queuedLayoutSaveCompleter != null &&
        !_queuedLayoutSaveCompleter!.isCompleted) {
      _queuedLayoutSaveCompleter!.complete();
    }
    _queuedLayoutSaveCompleter = null;
  }

  Future<void> _saveLayoutsDataNow() async {
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

        // Get payments - ensure it's a list with all payment details
        final payments = plotMap['payments'] as List<dynamic>? ?? [];
        final partners = (plotMap['partners'] as List<dynamic>? ?? [])
            .map((partner) => partner.toString().trim())
            .where((partner) => partner.isNotEmpty)
            .toList(growable: false);
        print(
            'DEBUG _saveLayoutsData: LAYOUT=${layoutIndex}_PLOT=${plotIndex} - Number=${plotMap['plotNumber']}, payments=${payments.isEmpty ? "EMPTY" : "${payments.length} items"}');
        final paymentsList = payments.map((payment) {
          if (payment is Map<String, dynamic>) {
            return Map<String, dynamic>.from(payment);
          }
          return payment;
        }).toList();

        return {
          'id': (plotMap['id'] ?? '').toString().trim(),
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
          'partners': partners,
          'payments': paymentsList,
        };
      }).toList();

      return {
        'id': (layout['id'] ?? '').toString().trim(),
        'name': layout['name'] as String? ?? 'Layout',
        'layoutImageName': (layout['layoutImageName'] ?? '').toString().trim(),
        'layoutImagePath': (layout['layoutImagePath'] ?? '').toString().trim(),
        'layoutImageDocId':
            (layout['layoutImageDocId'] ?? '').toString().trim(),
        'layoutImageExtension':
            (layout['layoutImageExtension'] ?? '').toString().trim(),
        'plots': plots,
      };
    }).toList();

    if (didAutoPromotePendingToSold && mounted) {
      setState(() {
        _rebuildAllPlotsFromLayouts(reason: 'auto_promote_status');
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
    var savedSuccessfully = false;
    if (widget.projectId != null && widget.projectId!.isNotEmpty) {
      try {
        final deltaLayouts = _buildLayoutsDeltaForRemoteSave(layoutsToSave);
        if (deltaLayouts.isNotEmpty) {
          _setSaveStatus(ProjectSaveStatusType.saving);
          await ProjectStorageService.saveProjectData(
            projectId: widget.projectId!,
            projectName: '', // Not updating project name
            layouts: deltaLayouts,
            partialLayoutsSync: true,
          );
        } else {
          print(
              '🔷 _saveLayoutsData: No remote layout/plot changes detected, skipping network save');
        }
        await _markRemoteSaveTimestamp();
        _markLocalSaveCompleted();
        _captureRemoteLayoutSignatures(layoutsToSave);
        savedSuccessfully = true;
      } catch (e) {
        print('Error saving plot status to Supabase: $e');
        // Local draft is already saved and will be retried on the next save.
        _setSaveStatus(
          e is ProjectSaveQueuedForSyncException
              ? ProjectSaveStatusType.queuedOffline
              : ProjectSaveStatusType.connectionLost,
        );
      }
    } else {
      // Save to local storage if no projectId
      await LayoutStorageService.saveLayoutsDataDirect(
        layoutsToSave,
        projectKey: widget.projectId,
      );
      _markLocalSaveCompleted();
      savedSuccessfully = true;
    }
    if (savedSuccessfully) {
      print('🔷 _saveLayoutsData COMPLETE: Save finished successfully');
    } else {
      print('🔶 _saveLayoutsData COMPLETE: Save finished with errors');
    }
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

  Future<void> _touchProjectUpdatedAt() async {
    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) return;
    try {
      await _supabase.from('projects').update(
        {'updated_at': DateTime.now().toIso8601String()},
      ).eq('id', projectId);
    } catch (e) {
      print('PlotStatusPage: Failed to touch project updated_at: $e');
    }
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
          'id': (plotMap['id'] ?? '').toString().trim(),
          'plotNumber': plotNumber,
          'area': area.isEmpty ? '0.00' : area,
          'status': plotStatus,
          'salePrice': plotMap['salePrice'] as String? ?? '',
          'buyerName': plotMap['buyerName'] as String? ?? '',
          'buyerContactNumber': (plotMap['buyerContactNumber'] ??
                  plotMap['buyer_contact_number'] ??
                  plotMap['buyer_mobile_number'] ??
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
      final layoutId = (layout['id'] ?? '').toString().trim();
      final layoutImageName =
          (layout['layoutImageName'] ?? layout['layout_image_name'] ?? '')
              .toString()
              .trim();
      final layoutImagePath =
          (layout['layoutImagePath'] ?? layout['layout_image_path'] ?? '')
              .toString()
              .trim();
      final layoutImageDocId =
          (layout['layoutImageDocId'] ?? layout['layout_image_doc_id'] ?? '')
              .toString()
              .trim();
      final layoutImageExtension = (layout['layoutImageExtension'] ??
              layout['layout_image_extension'] ??
              '')
          .toString()
          .trim();

      return {
        'id': layoutId,
        'name': layoutName.isEmpty ? 'Layout' : layoutName,
        'layoutImageName': layoutImageName,
        'layoutImagePath': layoutImagePath,
        'layoutImageDocId': layoutImageDocId,
        'layoutImageExtension': layoutImageExtension,
        'plots': plots,
      };
    }).toList();
  }

  String _getLayoutImageExtension(String fileName) {
    final parts = fileName.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : 'file';
  }

  String _sanitizeStorageFileName(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty) return 'file';
    final singleSpaced = trimmed.replaceAll(RegExp(r'\s+'), ' ');
    final sanitized = singleSpaced.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    return sanitized.isEmpty ? 'file' : sanitized;
  }

  String _getLayoutImageContentType(String extension) {
    const contentTypeMap = {
      'gif': 'image/gif',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'svg': 'image/svg+xml',
      'webp': 'image/webp',
    };
    return contentTypeMap[extension.toLowerCase()] ??
        'application/octet-stream';
  }

  String _buildLayoutImageUploadErrorMessage(
    Object error, {
    required String fileName,
    required int fileSizeBytes,
    required String contentType,
    required String storagePath,
  }) {
    if (error is StorageException) {
      final rawMessage = [
        error.message,
        if ((error.error ?? '').trim().isNotEmpty) error.error!.trim(),
      ].join(' ').trim();
      final lower = rawMessage.toLowerCase();
      if (lower.contains('mime') ||
          lower.contains('content type') ||
          lower.contains('invalid') && lower.contains('type')) {
        return 'Failed to upload layout image: Unsupported image type ($contentType). Please use PNG/JPG/WebP/GIF.';
      }
      if (lower.contains('size') ||
          lower.contains('too large') ||
          lower.contains('file_size_limit')) {
        return 'Failed to upload layout image: File is too large (${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB).';
      }
      if (lower.contains('invalid key') ||
          lower.contains('object name') ||
          lower.contains('path')) {
        return 'Failed to upload layout image: Invalid file name/path. Please rename the file and try again.';
      }
      if ((error.statusCode ?? '') == '400') {
        return 'Failed to upload layout image (400): ${rawMessage.isEmpty ? 'Bad request from storage API.' : rawMessage}';
      }
      return 'Failed to upload layout image (${error.statusCode ?? 'error'}): ${rawMessage.isEmpty ? error.toString() : rawMessage}';
    }
    return 'Failed to upload layout image: $error (file: $fileName, type: $contentType, path: $storagePath)';
  }

  String _resolveDocumentStoragePath(String urlOrPath) {
    final raw = urlOrPath.trim();
    if (raw.isEmpty) return '';
    final lowerRaw = raw.toLowerCase();
    final isHttpUrl =
        lowerRaw.startsWith('http://') || lowerRaw.startsWith('https://');
    if (!isHttpUrl) return raw;

    try {
      final uri = Uri.parse(raw);
      final index = uri.pathSegments.indexOf('documents');
      if (index >= 0 && index + 1 < uri.pathSegments.length) {
        final extracted = Uri.decodeComponent(
          uri.pathSegments.sublist(index + 1).join('/'),
        ).trim();
        if (extracted.isNotEmpty) return extracted;
      }
    } catch (_) {}

    final markerIndex = lowerRaw.indexOf('/documents/');
    if (markerIndex >= 0) {
      var extracted = raw.substring(markerIndex + '/documents/'.length);
      final queryIndex = extracted.indexOf('?');
      if (queryIndex >= 0) {
        extracted = extracted.substring(0, queryIndex);
      }
      final fragmentIndex = extracted.indexOf('#');
      if (fragmentIndex >= 0) {
        extracted = extracted.substring(0, fragmentIndex);
      }
      return Uri.decodeComponent(extracted).trim();
    }
    return '';
  }

  Future<String> _resolveDocumentPublicUrl(String storagePathOrUrl) async {
    final raw = storagePathOrUrl.trim();
    if (raw.isEmpty) return '';
    final resolvedStoragePath = _resolveDocumentStoragePath(raw);
    if (resolvedStoragePath.isEmpty) return '';
    if (resolvedStoragePath.startsWith('http')) return '';
    try {
      final signedUrl = await _supabase.storage
          .from('documents')
          .createSignedUrl(resolvedStoragePath, 3600);
      return signedUrl.trim();
    } catch (_) {
      return '';
    }
  }

  void _downloadFileViaBrowserUrl({
    required String fileUrl,
    required String fileName,
    html.WindowBase? preOpenedWindow,
  }) {
    if (!kIsWeb) {
      throw UnsupportedError(
          'Browser download helper is only available on web');
    }
    final normalizedUrl = fileUrl.trim();
    if (normalizedUrl.isEmpty) return;
    final suggestedName =
        fileName.trim().isEmpty ? 'download' : fileName.trim();
    if (preOpenedWindow != null) {
      preOpenedWindow.location.href = normalizedUrl;
      return;
    }
    final anchor = html.AnchorElement(href: normalizedUrl)
      ..download = suggestedName
      ..target = '_blank'
      ..rel = 'noopener noreferrer'
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
  }

  void _printImageViaBrowserWindow({
    required String imageUrl,
    required String title,
    html.WindowBase? preOpenedWindow,
  }) {
    if (!kIsWeb) {
      throw UnsupportedError('Browser print helper is only available on web');
    }
    final normalizedImageUrl = imageUrl.trim();
    if (normalizedImageUrl.isEmpty) return;

    final safeTitle =
        htmlEscape.convert(title.trim().isEmpty ? 'Image' : title);
    final safeImageUrl =
        const HtmlEscape(HtmlEscapeMode.attribute).convert(normalizedImageUrl);
    final printDocument = '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>$safeTitle</title>
    <style>
      html, body {
        margin: 0;
        padding: 0;
        width: 100%;
        height: 100%;
        background: #ffffff;
      }
      body {
        display: flex;
        align-items: center;
        justify-content: center;
      }
      img {
        max-width: 100vw;
        max-height: 100vh;
        object-fit: contain;
      }
    </style>
  </head>
  <body>
    <img src="$safeImageUrl" alt="$safeTitle" onload="setTimeout(function(){ window.focus(); window.print(); }, 120);" />
  </body>
</html>
''';
    final htmlBlob = html.Blob([printDocument], 'text/html');
    final htmlBlobUrl = html.Url.createObjectUrlFromBlob(htmlBlob);
    if (preOpenedWindow != null) {
      preOpenedWindow.location.href = htmlBlobUrl;
    } else {
      html.window.open(htmlBlobUrl, '_blank', 'width=1200,height=900');
    }
    Future<void>.delayed(const Duration(minutes: 2), () {
      html.Url.revokeObjectUrl(htmlBlobUrl);
    });
  }

  void _closeBrowserPopupWindow(html.WindowBase? popupWindow) {
    if (popupWindow == null) return;
    try {
      popupWindow.close();
    } catch (_) {}
  }

  html.WindowBase? _tryPreOpenBrowserWindow() {
    if (!kIsWeb) return null;
    try {
      return html.window.open('', '_blank', 'width=1200,height=900');
    } catch (_) {
      return null;
    }
  }

  Future<void> _openUrlExternally(String rawUrl) async {
    final url = rawUrl.trim();
    if (url.isEmpty) {
      throw Exception('Empty URL');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || (!uri.hasScheme && uri.host.isEmpty)) {
      throw Exception('Invalid URL');
    }
    var launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
    if (!launched) {
      throw Exception('Could not open file');
    }
  }

  Future<void> _downloadFileForCurrentPlatform({
    required String fileUrl,
    required String fileName,
    html.WindowBase? preOpenedWindow,
  }) async {
    final normalizedUrl = fileUrl.trim();
    if (normalizedUrl.isEmpty) return;
    final suggestedName =
        fileName.trim().isEmpty ? 'download' : fileName.trim();
    if (kIsWeb) {
      _downloadFileViaBrowserUrl(
        fileUrl: normalizedUrl,
        fileName: suggestedName,
        preOpenedWindow: preOpenedWindow,
      );
      return;
    }

    final response = await http.get(Uri.parse(normalizedUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final mimeType = (response.headers['content-type'] ?? '').trim().isNotEmpty
        ? response.headers['content-type']!.trim()
        : 'application/octet-stream';
    final bytes = Uint8List.fromList(response.bodyBytes);
    if (bytes.isEmpty) {
      throw Exception('Empty download response');
    }
    final saved = await saveBytesToUserDevice(
      bytes: bytes,
      suggestedFileName: suggestedName,
      mimeType: mimeType,
    );
    if (!saved) {
      return;
    }
  }

  Future<void> _printImageForCurrentPlatform({
    required String imageUrl,
    required String title,
    html.WindowBase? preOpenedWindow,
  }) async {
    final normalizedImageUrl = imageUrl.trim();
    if (normalizedImageUrl.isEmpty) return;
    await printSingleImage(
      imageUrl: normalizedImageUrl,
      title: title,
      preOpenedWindow: preOpenedWindow,
    );
  }

  String _extractFileExtensionFromPathOrUrl(String pathOrUrl) {
    final raw = pathOrUrl.trim();
    if (raw.isEmpty) return '';
    final withoutQuery = raw.split('?').first.split('#').first;
    final slash = withoutQuery.lastIndexOf('/');
    final fileName =
        slash >= 0 ? withoutQuery.substring(slash + 1) : withoutQuery;
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot >= fileName.length - 1) return '';
    return fileName.substring(dot + 1).trim().toLowerCase();
  }

  String _layoutImageDownloadName({
    required bool isAmenityImage,
    int? layoutIndex,
    required String fallbackLabel,
    String? storagePathOrUrl,
  }) {
    String name = '';
    String extension = '';
    if (isAmenityImage) {
      name = _amenityLayoutImageName.trim();
      extension = _amenityLayoutImageExtension.trim().toLowerCase();
    } else if (layoutIndex != null &&
        layoutIndex >= 0 &&
        layoutIndex < _layouts.length) {
      final layout = _layouts[layoutIndex];
      name = (layout['layoutImageName'] ?? '').toString().trim();
      extension = (layout['layoutImageExtension'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
    }
    if (extension.isEmpty) {
      extension = _extractFileExtensionFromPathOrUrl(
        (storagePathOrUrl ?? '').trim(),
      );
    }
    if (name.isNotEmpty) return name;

    final fallback =
        fallbackLabel.trim().isEmpty ? 'layout_image' : fallbackLabel.trim();
    if (extension.isNotEmpty) return '$fallback.$extension';
    return '$fallback.png';
  }

  String? _layoutIdFromStoragePath(String storagePath) {
    final match = RegExp(r'/layout_([^/]+)/').firstMatch(storagePath.trim());
    final extracted = (match?.group(1) ?? '').trim();
    return extracted.isEmpty ? null : extracted;
  }

  Future<String?> _findRootDocumentsFolderIdByName(String folderName) async {
    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) return null;

    final existing = await _supabase
        .from('documents')
        .select('id,parent_id,name,created_at')
        .eq('project_id', projectId)
        .eq('type', 'folder')
        .order('created_at', ascending: true);

    if (existing is! List || existing.isEmpty) return null;

    final wanted = folderName.trim().toLowerCase();
    for (final row in existing) {
      if (row is! Map) continue;
      final parentId = row['parent_id'];
      final isRoot = parentId == null || parentId.toString().trim().isEmpty;
      if (!isRoot) continue;
      final rowName = (row['name'] ?? '').toString().trim().toLowerCase();
      if (rowName != wanted) continue;
      final id = (row['id'] ?? '').toString().trim();
      if (id.isNotEmpty) return id;
    }

    return null;
  }

  Future<String?> _ensureRootDocumentsFolderIdByName(String folderName) async {
    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) return null;

    final existingFolderId = await _findRootDocumentsFolderIdByName(folderName);
    if (existingFolderId != null && existingFolderId.isNotEmpty) {
      return existingFolderId;
    }

    try {
      final inserted = await _supabase
          .from('documents')
          .insert({
            'project_id': projectId,
            'name': folderName,
            'type': 'folder',
            'parent_id': null,
          })
          .select('id')
          .single();
      return (inserted['id'] ?? '').toString().trim();
    } catch (_) {
      return _findRootDocumentsFolderIdByName(folderName);
    }
  }

  Future<String?> _ensureLayoutDocumentsFolderId() async {
    return _ensureRootDocumentsFolderIdByName(_layoutDocumentsFolderName);
  }

  Future<String?> _ensureAmenityDocumentsFolderId() async {
    return _ensureRootDocumentsFolderIdByName(_amenityDocumentsFolderName);
  }

  Future<String?> _ensureLayoutImageSubfolderId({
    required String projectId,
    required String layoutsFolderId,
    required String layoutId,
    required String layoutName,
  }) async {
    final normalizedLayoutId = layoutId.trim();
    if (normalizedLayoutId.isEmpty) return null;

    final preferredName = layoutName.trim().isNotEmpty
        ? layoutName.trim()
        : 'Layout ${normalizedLayoutId.substring(0, math.min(6, normalizedLayoutId.length))}';

    try {
      final sameNameRows = await _supabase
          .from('documents')
          .select('id,name')
          .eq('project_id', projectId)
          .eq('type', 'folder')
          .eq('parent_id', layoutsFolderId)
          .eq('name', preferredName)
          .limit(1);
      if (sameNameRows is List && sameNameRows.isNotEmpty) {
        final existingId = (sameNameRows.first['id'] ?? '').toString().trim();
        if (existingId.isNotEmpty) return existingId;
      }
    } catch (_) {}

    try {
      final existingFolders = await _supabase
          .from('documents')
          .select('id,name')
          .eq('project_id', projectId)
          .eq('type', 'folder')
          .eq('parent_id', layoutsFolderId)
          .order('created_at', ascending: false)
          .limit(200);

      if (existingFolders is List && existingFolders.isNotEmpty) {
        for (final raw in existingFolders) {
          if (raw is! Map) continue;
          final candidateId = (raw['id'] ?? '').toString().trim();
          if (candidateId.isEmpty) continue;
          final fileRows = await _supabase
              .from('documents')
              .select('file_url')
              .eq('project_id', projectId)
              .eq('type', 'file')
              .eq('parent_id', candidateId)
              .order('created_at', ascending: false)
              .limit(30);
          for (final fileRaw in fileRows) {
            if (fileRaw is! Map) continue;
            final fileUrl = (fileRaw['file_url'] ?? '').toString().trim();
            final resolvedLayoutId = _layoutIdFromStoragePath(fileUrl);
            if (resolvedLayoutId == normalizedLayoutId) {
              return candidateId;
            }
          }
        }
      }
    } catch (_) {}

    try {
      final inserted = await _supabase
          .from('documents')
          .insert({
            'project_id': projectId,
            'name': preferredName,
            'type': 'folder',
            'parent_id': layoutsFolderId,
          })
          .select('id')
          .single();
      final insertedId = (inserted['id'] ?? '').toString().trim();
      return insertedId.isEmpty ? null : insertedId;
    } catch (_) {
      try {
        final retry = await _supabase
            .from('documents')
            .select('id')
            .eq('project_id', projectId)
            .eq('type', 'folder')
            .eq('parent_id', layoutsFolderId)
            .eq('name', preferredName)
            .limit(1);
        if (retry is List && retry.isNotEmpty) {
          final retryId = (retry.first['id'] ?? '').toString().trim();
          if (retryId.isNotEmpty) return retryId;
        }
      } catch (_) {}
      return null;
    }
  }

  Future<String?> _resolveLayoutIdForDocument(int layoutIndex) async {
    if (layoutIndex < 0 || layoutIndex >= _layouts.length) return null;

    final existingId = (_layouts[layoutIndex]['id'] ?? '').toString().trim();
    if (existingId.isNotEmpty) return existingId;

    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) return null;

    final layoutName = (_layouts[layoutIndex]['name'] ?? '').toString().trim();
    if (layoutName.isEmpty) return null;

    try {
      final row = await _supabase
          .from('layouts')
          .select('id')
          .eq('project_id', projectId)
          .eq('name', layoutName)
          .maybeSingle();
      final resolvedId = (row?['id'] ?? '').toString().trim();
      if (resolvedId.isEmpty) return null;
      _layouts[layoutIndex]['id'] = resolvedId;
      return resolvedId;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _findLatestLayoutDocumentRow({
    required String projectId,
    required String layoutId,
  }) async {
    final rows = await _supabase
        .from('documents')
        .select('id,name,file_url,extension,created_at')
        .eq('project_id', projectId)
        .eq('type', 'file')
        .order('created_at', ascending: false)
        .limit(500);

    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final fileUrl = (row['file_url'] ?? '').toString().trim();
      final resolvedLayoutId = _layoutIdFromStoragePath(fileUrl);
      if (resolvedLayoutId == layoutId) {
        return row;
      }
    }
    return null;
  }

  Future<Map<String, String>> _resolveDocumentDeletionTargets({
    required String projectId,
    required String docId,
    required String urlOrPath,
  }) async {
    var resolvedDocId = docId.trim();
    var resolvedStoragePath = _resolveDocumentStoragePath(urlOrPath);
    var parentFolderId = '';

    if (resolvedDocId.isNotEmpty) {
      final byId = await _supabase
          .from('documents')
          .select('id,file_url,parent_id')
          .eq('id', resolvedDocId)
          .maybeSingle();
      if (byId != null) {
        resolvedDocId = (byId['id'] ?? resolvedDocId).toString().trim();
        final byIdPath = _resolveDocumentStoragePath(
          (byId['file_url'] ?? '').toString(),
        );
        if (byIdPath.isNotEmpty) {
          resolvedStoragePath = byIdPath;
        }
        parentFolderId = (byId['parent_id'] ?? '').toString().trim();
      }
    }

    if (resolvedDocId.isEmpty && resolvedStoragePath.isNotEmpty) {
      final byPath = await _supabase
          .from('documents')
          .select('id,parent_id')
          .eq('project_id', projectId)
          .eq('file_url', resolvedStoragePath)
          .limit(1)
          .maybeSingle();
      if (byPath != null) {
        resolvedDocId = (byPath['id'] ?? '').toString().trim();
        parentFolderId = (byPath['parent_id'] ?? '').toString().trim();
      }
    }

    return {
      'docId': resolvedDocId,
      'storagePath': resolvedStoragePath,
      'parentFolderId': parentFolderId,
    };
  }

  Future<void> _deleteLayoutChildFolderIfEmpty({
    required String projectId,
    required String folderId,
  }) async {
    final trimmedFolderId = folderId.trim();
    if (trimmedFolderId.isEmpty) return;

    try {
      final folderRow = await _supabase
          .from('documents')
          .select('id,type,parent_id')
          .eq('id', trimmedFolderId)
          .eq('project_id', projectId)
          .maybeSingle();
      if (folderRow == null) return;
      if ((folderRow['type'] ?? '').toString().toLowerCase() != 'folder')
        return;

      final parentId = (folderRow['parent_id'] ?? '').toString().trim();
      if (parentId.isEmpty) return;

      final parentRow = await _supabase
          .from('documents')
          .select('id,name,parent_id,type')
          .eq('id', parentId)
          .eq('project_id', projectId)
          .maybeSingle();
      if (parentRow == null) return;
      if ((parentRow['type'] ?? '').toString().toLowerCase() != 'folder')
        return;
      final parentName =
          (parentRow['name'] ?? '').toString().trim().toLowerCase();
      if (parentName != _layoutDocumentsFolderName.toLowerCase()) return;
      final parentParentId = (parentRow['parent_id'] ?? '').toString().trim();
      if (parentParentId.isNotEmpty) return;

      final children = await _supabase
          .from('documents')
          .select('id')
          .eq('project_id', projectId)
          .eq('parent_id', trimmedFolderId)
          .limit(1);
      if (children is List && children.isNotEmpty) return;

      await _supabase.from('documents').delete().eq('id', trimmedFolderId);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _findLatestAmenityLayoutDocumentRow({
    required String projectId,
    required String folderId,
  }) async {
    final rows = await _supabase
        .from('documents')
        .select('id,name,file_url,extension,created_at')
        .eq('project_id', projectId)
        .eq('type', 'file')
        .eq('parent_id', folderId)
        .order('created_at', ascending: false)
        .limit(200);

    const imageExtensions = <String>{
      'png',
      'jpg',
      'jpeg',
      'webp',
      'gif',
      'svg',
    };
    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final extension =
          (row['extension'] ?? '').toString().trim().toLowerCase();
      final name = (row['name'] ?? '').toString().trim().toLowerCase();
      final inferredExt = extension.isNotEmpty
          ? extension
          : (name.contains('.') ? name.split('.').last : '');
      if (!imageExtensions.contains(inferredExt)) continue;
      return row;
    }
    return null;
  }

  Future<void> _syncAmenityLayoutImageFromDocumentsIfMissing({
    required String projectId,
  }) async {
    final hasMetadata = _amenityLayoutImagePath.trim().isNotEmpty ||
        _amenityLayoutImageDocId.trim().isNotEmpty;
    if (hasMetadata) return;

    final amenityFolderId =
        await _findRootDocumentsFolderIdByName(_amenityDocumentsFolderName);
    if (amenityFolderId == null || amenityFolderId.isEmpty) return;

    final latest = await _findLatestAmenityLayoutDocumentRow(
      projectId: projectId,
      folderId: amenityFolderId,
    );
    if (latest == null) return;

    final storagePath = (latest['file_url'] ?? '').toString().trim();
    final docId = (latest['id'] ?? '').toString().trim();
    final fileName = (latest['name'] ?? '').toString().trim();
    final extension = (latest['extension'] ?? '').toString().trim();
    if (storagePath.isEmpty && docId.isEmpty) return;

    if (mounted) {
      setState(() {
        _amenityLayoutImagePath = storagePath;
        _amenityLayoutImageDocId = docId;
        _amenityLayoutImageName = fileName;
        _amenityLayoutImageExtension = extension;
      });
    } else {
      _amenityLayoutImagePath = storagePath;
      _amenityLayoutImageDocId = docId;
      _amenityLayoutImageName = fileName;
      _amenityLayoutImageExtension = extension;
    }

    await _persistAmenityLayoutImageMetaToProject(
      imageName: fileName,
      imagePath: storagePath,
      imageDocId: docId,
      imageExtension: extension,
    );
  }

  Future<void> _persistLayoutImageMetaToLayout({
    required String layoutId,
    required String imageName,
    required String imagePath,
    required String imageDocId,
    required String imageExtension,
  }) async {
    if (layoutId.trim().isEmpty) return;
    try {
      await _supabase.from('layouts').update({
        'layout_image_name': imageName.trim().isEmpty ? null : imageName.trim(),
        'layout_image_path': imagePath.trim().isEmpty ? null : imagePath.trim(),
        'layout_image_doc_id':
            imageDocId.trim().isEmpty ? null : imageDocId.trim(),
        'layout_image_extension':
            imageExtension.trim().isEmpty ? null : imageExtension.trim(),
      }).eq('id', layoutId);
      await _touchProjectUpdatedAt();
    } catch (e) {
      print('PlotStatusPage: Layout image metadata sync skipped: $e');
    }
  }

  Future<void> _persistAmenityLayoutImageMetaToProject({
    required String imageName,
    required String imagePath,
    required String imageDocId,
    required String imageExtension,
  }) async {
    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) return;
    try {
      await _supabase.from('projects').update({
        'updated_at': DateTime.now().toIso8601String(),
        'amenity_layout_image_name':
            imageName.trim().isEmpty ? null : imageName.trim(),
        'amenity_layout_image_path':
            imagePath.trim().isEmpty ? null : imagePath.trim(),
        'amenity_layout_image_doc_id':
            imageDocId.trim().isEmpty ? null : imageDocId.trim(),
        'amenity_layout_image_extension':
            imageExtension.trim().isEmpty ? null : imageExtension.trim(),
      }).eq('id', projectId);
    } catch (e) {
      print('PlotStatusPage: Amenity layout image metadata sync skipped: $e');
    }
  }

  String _buildEditedLayoutImageStoragePath({
    required String basePath,
    required String imageName,
  }) {
    final normalizedBasePath = _resolveDocumentStoragePath(basePath);
    final slashIndex = normalizedBasePath.lastIndexOf('/');
    final folderPath =
        slashIndex >= 0 ? normalizedBasePath.substring(0, slashIndex) : '';
    final safeImageName = _sanitizeStorageFileName(
      imageName.trim().isEmpty ? 'layout_image' : imageName.trim(),
    );
    final dotIndex = safeImageName.lastIndexOf('.');
    final baseName =
        dotIndex > 0 ? safeImageName.substring(0, dotIndex) : safeImageName;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final nextFileName = '${baseName}_edited_$timestamp.png';
    return folderPath.isEmpty ? nextFileName : '$folderPath/$nextFileName';
  }

  bool _bytesLookLikeSvg(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final sampleLength = math.min(bytes.length, 512);
    final sample = utf8.decode(
      bytes.sublist(0, sampleLength),
      allowMalformed: true,
    );
    final normalized = sample.toLowerCase();
    return normalized.contains('<svg') || normalized.contains('<?xml');
  }

  Future<Map<String, dynamic>> _decodeCompositeSourceImage({
    required Uint8List bytes,
    required String contentType,
    required Size drawingCanvasSize,
    required Size drawingImageSize,
  }) async {
    final normalizedType = contentType.toLowerCase();
    final looksLikeSvg =
        normalizedType.contains('svg') || _bytesLookLikeSvg(bytes);

    if (!looksLikeSvg) {
      try {
        final codec = await instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final image = frame.image;
        return {
          'image': image,
          'width': math.max(1, image.width),
          'height': math.max(1, image.height),
        };
      } catch (_) {
        if (!_bytesLookLikeSvg(bytes)) rethrow;
      }
    }

    final svgText = utf8.decode(bytes, allowMalformed: true);
    final pictureInfo = await vg.loadPicture(SvgStringLoader(svgText), null);
    try {
      final intrinsicSize = pictureInfo.size;
      final referenceSize =
          (drawingImageSize.width > 0 && drawingImageSize.height > 0)
              ? drawingImageSize
              : drawingCanvasSize;
      final baseWidth = intrinsicSize.width > 0
          ? intrinsicSize.width
          : (referenceSize.width > 0 ? referenceSize.width : 2048.0);
      final baseHeight = intrinsicSize.height > 0
          ? intrinsicSize.height
          : (referenceSize.height > 0 ? referenceSize.height : 2048.0);
      final baseLongest = math.max(baseWidth, baseHeight);
      final referenceLongest = math.max(
        referenceSize.width,
        referenceSize.height,
      );
      final targetLongest = math.min(
        8192.0,
        math.max(
          3072.0,
          math.max(
              baseLongest, referenceLongest > 0 ? referenceLongest * 3 : 0),
        ),
      );
      final baseScale = baseLongest > 0 ? targetLongest / baseLongest : 1.0;
      var rasterWidth = math.max(1.0, baseWidth * baseScale);
      var rasterHeight = math.max(1.0, baseHeight * baseScale);
      const maxPixels = 40000000.0;
      final pixelCount = rasterWidth * rasterHeight;
      if (pixelCount > maxPixels) {
        final shrink = math.sqrt(maxPixels / pixelCount);
        rasterWidth = math.max(1.0, rasterWidth * shrink);
        rasterHeight = math.max(1.0, rasterHeight * shrink);
      }
      final width = math.max(1, rasterWidth.round());
      final height = math.max(1, rasterHeight.round());

      final rasterImage = await pictureInfo.picture.toImage(
        math.max(1, width),
        math.max(1, height),
      );
      return {
        'image': rasterImage,
        'width': math.max(1, width),
        'height': math.max(1, height),
      };
    } finally {
      pictureInfo.picture.dispose();
    }
  }

  Future<Uint8List> _renderLayoutViewerCompositePng({
    required String imageUrl,
    required List<_LayoutViewerStroke> strokes,
    required Size drawingCanvasSize,
    Size drawingImageSize = Size.zero,
  }) async {
    final response = await http.get(Uri.parse(imageUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Could not load source image (${response.statusCode})');
    }
    final decoded = await _decodeCompositeSourceImage(
      bytes: response.bodyBytes,
      contentType: response.headers['content-type'] ?? '',
      drawingCanvasSize: drawingCanvasSize,
      drawingImageSize: drawingImageSize,
    );
    final sourceImage = decoded['image'];
    final width = decoded['width'] as int;
    final height = decoded['height'] as int;
    print(
      'PlotStatusPage: Layout edit render size $width x $height (content-type: ${response.headers['content-type'] ?? 'unknown'})',
    );
    final referenceSize =
        (drawingImageSize.width > 0 && drawingImageSize.height > 0)
            ? drawingImageSize
            : drawingCanvasSize;
    final widthScale =
        referenceSize.width > 0 ? width / referenceSize.width : 1.0;
    final heightScale =
        referenceSize.height > 0 ? height / referenceSize.height : 1.0;
    final strokeScale = math.min(widthScale, heightScale);

    final recorder = PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    canvas.drawImageRect(
      sourceImage,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint(),
    );

    for (final stroke in strokes) {
      if (stroke.normalizedPoints.isEmpty) continue;
      final lineWidth = math.max(1.0, stroke.thickness * 2.0 * strokeScale);

      if (stroke.normalizedPoints.length == 1) {
        final p = stroke.normalizedPoints.first;
        final dotPaint = Paint()
          ..color = stroke.color
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
        canvas.drawCircle(
          Offset(p.dx * width, p.dy * height),
          lineWidth / 2,
          dotPaint,
        );
        continue;
      }

      final first = stroke.normalizedPoints.first;
      final path = Path()..moveTo(first.dx * width, first.dy * height);
      for (int i = 1; i < stroke.normalizedPoints.length; i++) {
        final point = stroke.normalizedPoints[i];
        path.lineTo(point.dx * width, point.dy * height);
      }
      final strokePaint = Paint()
        ..color = stroke.color
        ..strokeWidth = lineWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      canvas.drawPath(path, strokePaint);
    }

    final picture = recorder.endRecording();
    final composedImage = await picture.toImage(width, height);
    final bytes = await composedImage.toByteData(format: ImageByteFormat.png);
    if (bytes == null) {
      throw Exception('Could not encode edited image');
    }
    print('PlotStatusPage: Layout edit output bytes ${bytes.lengthInBytes}');
    return bytes.buffer.asUint8List();
  }

  Future<Size> _fetchImageNaturalSizeFromUrl(String imageUrl) async {
    final response = await http.get(Uri.parse(imageUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Could not load image (${response.statusCode})');
    }
    try {
      final codec = await instantiateImageCodec(response.bodyBytes);
      final frame = await codec.getNextFrame();
      return Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
    } catch (_) {
      if (!_bytesLookLikeSvg(response.bodyBytes)) rethrow;
      final svgText = utf8.decode(response.bodyBytes, allowMalformed: true);
      final pictureInfo = await vg.loadPicture(SvgStringLoader(svgText), null);
      try {
        return pictureInfo.size;
      } finally {
        pictureInfo.picture.dispose();
      }
    }
  }

  Future<void> _savePlotStatusLayoutViewerEdits({
    required int layoutIndex,
    required List<_LayoutViewerStroke> strokes,
    required Size drawingCanvasSize,
    Size drawingImageSize = Size.zero,
  }) async {
    if (layoutIndex < 0 || layoutIndex >= _layouts.length || strokes.isEmpty) {
      return;
    }
    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) {
      throw Exception('Please save project first.');
    }

    String baseStoragePath = _resolveDocumentStoragePath(
      (_layouts[layoutIndex]['layoutImagePath'] ?? '').toString(),
    );
    String docId =
        (_layouts[layoutIndex]['layoutImageDocId'] ?? '').toString().trim();

    if (baseStoragePath.isEmpty && docId.isNotEmpty) {
      final byId = await _supabase
          .from('documents')
          .select('file_url')
          .eq('id', docId)
          .maybeSingle();
      baseStoragePath = _resolveDocumentStoragePath(
        (byId?['file_url'] ?? '').toString(),
      );
    }
    if (baseStoragePath.isEmpty) {
      throw Exception('No layout image storage path found.');
    }
    final baseImageUrl = await _resolveDocumentPublicUrl(baseStoragePath);
    if (baseImageUrl.isEmpty) {
      throw Exception('Could not resolve layout image URL.');
    }

    final editedBytes = await _renderLayoutViewerCompositePng(
      imageUrl: baseImageUrl,
      strokes: strokes,
      drawingCanvasSize: drawingCanvasSize,
      drawingImageSize: drawingImageSize,
    );
    final currentImageName =
        (_layouts[layoutIndex]['layoutImageName'] ?? '').toString().trim();
    final nextStoragePath = _buildEditedLayoutImageStoragePath(
      basePath: baseStoragePath,
      imageName: currentImageName,
    );
    final nextImageName = nextStoragePath.split('/').last.trim().isEmpty
        ? (currentImageName.isEmpty
            ? 'layout_image_edited.png'
            : currentImageName)
        : nextStoragePath.split('/').last.trim();

    _setSaveStatus(ProjectSaveStatusType.uploadingFile);
    await _supabase.storage.from('documents').uploadBinary(
          nextStoragePath,
          editedBytes,
          fileOptions: const FileOptions(
            contentType: 'image/png',
            cacheControl: '3600',
            upsert: true,
          ),
        );

    if (docId.isEmpty) {
      final byPath = await _supabase
          .from('documents')
          .select('id')
          .eq('project_id', projectId)
          .eq('file_url', baseStoragePath)
          .limit(1)
          .maybeSingle();
      docId = (byPath?['id'] ?? '').toString().trim();
    }

    if (docId.isNotEmpty) {
      await _supabase.from('documents').update({
        'name': nextImageName,
        'extension': 'png',
        'file_url': nextStoragePath,
        'file_size': editedBytes.length,
      }).eq('id', docId);
    }

    if (mounted) {
      setState(() {
        _layouts[layoutIndex]['layoutImagePath'] = nextStoragePath;
        _layouts[layoutIndex]['layoutImageDocId'] = docId;
        _layouts[layoutIndex]['layoutImageName'] = nextImageName;
        _layouts[layoutIndex]['layoutImageExtension'] = 'png';
      });
    } else {
      _layouts[layoutIndex]['layoutImagePath'] = nextStoragePath;
      _layouts[layoutIndex]['layoutImageDocId'] = docId;
      _layouts[layoutIndex]['layoutImageName'] = nextImageName;
      _layouts[layoutIndex]['layoutImageExtension'] = 'png';
    }

    final layoutId = await _resolveLayoutIdForDocument(layoutIndex);
    if (layoutId != null && layoutId.isNotEmpty) {
      await _persistLayoutImageMetaToLayout(
        layoutId: layoutId,
        imageName: nextImageName,
        imagePath: nextStoragePath,
        imageDocId: docId,
        imageExtension: 'png',
      );
    }
    await _saveLayoutsData(immediate: true);
  }

  Future<void> _savePlotStatusAmenityLayoutViewerEdits({
    required List<_LayoutViewerStroke> strokes,
    required Size drawingCanvasSize,
    Size drawingImageSize = Size.zero,
  }) async {
    if (strokes.isEmpty) return;

    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) {
      throw Exception('Please save project first.');
    }

    String baseStoragePath =
        _resolveDocumentStoragePath(_amenityLayoutImagePath);
    String docId = _amenityLayoutImageDocId.trim();

    if (baseStoragePath.isEmpty && docId.isNotEmpty) {
      final byId = await _supabase
          .from('documents')
          .select('file_url')
          .eq('id', docId)
          .maybeSingle();
      baseStoragePath = _resolveDocumentStoragePath(
        (byId?['file_url'] ?? '').toString(),
      );
    }
    if (baseStoragePath.isEmpty) {
      throw Exception('No layout image storage path found.');
    }
    final baseImageUrl = await _resolveDocumentPublicUrl(baseStoragePath);
    if (baseImageUrl.isEmpty) {
      throw Exception('Could not resolve layout image URL.');
    }

    final editedBytes = await _renderLayoutViewerCompositePng(
      imageUrl: baseImageUrl,
      strokes: strokes,
      drawingCanvasSize: drawingCanvasSize,
      drawingImageSize: drawingImageSize,
    );
    final currentImageName = _amenityLayoutImageName.trim();
    final nextStoragePath = _buildEditedLayoutImageStoragePath(
      basePath: baseStoragePath,
      imageName: currentImageName,
    );
    final nextImageName = nextStoragePath.split('/').last.trim().isEmpty
        ? (currentImageName.isEmpty
            ? 'layout_image_edited.png'
            : currentImageName)
        : nextStoragePath.split('/').last.trim();

    _setSaveStatus(ProjectSaveStatusType.uploadingFile);
    await _supabase.storage.from('documents').uploadBinary(
          nextStoragePath,
          editedBytes,
          fileOptions: const FileOptions(
            contentType: 'image/png',
            cacheControl: '3600',
            upsert: true,
          ),
        );

    if (docId.isEmpty) {
      final byPath = await _supabase
          .from('documents')
          .select('id')
          .eq('project_id', projectId)
          .eq('file_url', baseStoragePath)
          .limit(1)
          .maybeSingle();
      docId = (byPath?['id'] ?? '').toString().trim();
    }

    if (docId.isNotEmpty) {
      await _supabase.from('documents').update({
        'name': nextImageName,
        'extension': 'png',
        'file_url': nextStoragePath,
        'file_size': editedBytes.length,
      }).eq('id', docId);
    }

    if (mounted) {
      setState(() {
        _amenityLayoutImagePath = nextStoragePath;
        _amenityLayoutImageDocId = docId;
        _amenityLayoutImageName = nextImageName;
        _amenityLayoutImageExtension = 'png';
      });
    } else {
      _amenityLayoutImagePath = nextStoragePath;
      _amenityLayoutImageDocId = docId;
      _amenityLayoutImageName = nextImageName;
      _amenityLayoutImageExtension = 'png';
    }

    await _persistAmenityLayoutImageMetaToProject(
      imageName: nextImageName,
      imagePath: nextStoragePath,
      imageDocId: docId,
      imageExtension: 'png',
    );
  }

  Future<void> _uploadLayoutDocumentForLayout(int layoutIndex) async {
    if (layoutIndex < 0 || layoutIndex >= _layouts.length) return;
    if (_layoutImageUploadInProgress.contains(layoutIndex)) return;

    final projectId = widget.projectId?.trim();
    String debugFileName = 'unknown';
    int debugFileSizeBytes = 0;
    String debugContentType = 'unknown';
    String debugStoragePath = 'unknown';

    if (projectId == null || projectId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please save project first.')),
        );
      }
      return;
    }
    var canAttemptRemoteUpload = widget.isNetworkReachable;
    if (canAttemptRemoteUpload) {
      final remoteProjectReady =
          await ProjectStorageService.ensureRemoteProjectExistsForDocumentSync(
        projectId,
      );
      canAttemptRemoteUpload = remoteProjectReady;
    }

    if (mounted) {
      setState(() {
        _layoutImageUploadInProgress.add(layoutIndex);
      });
    } else {
      _layoutImageUploadInProgress.add(layoutIndex);
    }

    try {
      final file = await pickSingleLocalFile(
        allowedExtensions: const <String>[
          'png',
          'jpg',
          'jpeg',
          'webp',
          'gif',
        ],
      );
      if (file == null) return;
      _setSaveStatus(ProjectSaveStatusType.uploadingFile);

      String? layoutId = await _resolveLayoutIdForDocument(layoutIndex);
      if (layoutId == null || layoutId.isEmpty) {
        // Try to persist pending layout changes first, then resolve again.
        await _saveLayoutsData(immediate: true);
        layoutId = await _resolveLayoutIdForDocument(layoutIndex);
      }
      final resolvedLayoutId = (layoutId ?? '').trim();
      final layoutPathKey = resolvedLayoutId.isNotEmpty
          ? resolvedLayoutId
          : 'draft_${layoutIndex + 1}';

      final layoutsFolderId =
          (await _ensureLayoutDocumentsFolderId())?.trim() ?? '';
      final storageLayoutsFolderSegment =
          layoutsFolderId.isNotEmpty ? layoutsFolderId : 'layouts';

      final layoutName =
          (_layouts[layoutIndex]['name'] ?? '').toString().trim();
      String layoutFolderId = '';
      if (layoutsFolderId.isNotEmpty) {
        layoutFolderId = (await _ensureLayoutImageSubfolderId(
              projectId: projectId,
              layoutsFolderId: layoutsFolderId,
              layoutId: layoutPathKey,
              layoutName: layoutName,
            ))
                ?.trim() ??
            '';
      }
      final parentFolderIdForDoc = layoutFolderId;
      final storageLayoutFolderSegment =
          layoutFolderId.isNotEmpty ? layoutFolderId : 'layout_$layoutPathKey';

      final fileName = file.name;
      final extension = _getLayoutImageExtension(fileName);
      final allowedImageExtensions = <String>{
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
      };
      if (!allowedImageExtensions.contains(extension)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Unsupported image format "$extension". Please upload PNG/JPG/WebP/GIF.',
              ),
            ),
          );
        }
        return;
      }

      final storageFileName = _sanitizeStorageFileName(fileName);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final storagePath =
          '$projectId/$storageLayoutsFolderSegment/$storageLayoutFolderSegment/$timestamp-$storageFileName';
      final contentType = file.mimeType.isEmpty
          ? _getLayoutImageContentType(extension)
          : file.mimeType;
      debugFileName = fileName;
      debugFileSizeBytes = file.sizeBytes;
      debugContentType = contentType;
      debugStoragePath = storagePath;
      final bytes = file.bytes;

      var queuedOfflineUpload = false;
      var insertedDocId = '';
      var storedPath = storagePath;
      var resolvedName = fileName;
      var resolvedExtension = extension;

      Future<void> queueOfflineUpload() async {
        await OfflineFileUploadQueueService.enqueueLayoutImageUpload(
          projectId: projectId,
          bytes: bytes,
          fileName: fileName,
          extension: extension,
          contentType: contentType,
          storagePath: storagePath,
          parentFolderId: parentFolderIdForDoc,
          fileSizeBytes: file.sizeBytes,
          layoutId: resolvedLayoutId,
          layoutName: layoutName,
        );
        queuedOfflineUpload = true;
      }

      if (canAttemptRemoteUpload) {
        try {
          await _supabase.storage.from('documents').uploadBinary(
                storagePath,
                bytes,
                fileOptions: FileOptions(
                  contentType: contentType,
                  cacheControl: '3600',
                  upsert: false,
                ),
              );

          final insertedDoc = await _supabase
              .from('documents')
              .insert({
                'project_id': projectId,
                'name': fileName,
                'type': 'file',
                'extension': extension,
                'parent_id':
                    parentFolderIdForDoc.isEmpty ? null : parentFolderIdForDoc,
                'file_url': storagePath,
                'file_size': file.sizeBytes,
              })
              .select('id,extension,file_url,name')
              .maybeSingle();

          insertedDocId = (insertedDoc?['id'] ?? '').toString().trim();
          storedPath =
              (insertedDoc?['file_url'] ?? storagePath).toString().trim();
          resolvedName = (insertedDoc?['name'] ?? fileName).toString().trim();
          resolvedExtension =
              (insertedDoc?['extension'] ?? extension).toString().trim();
        } catch (uploadError) {
          if (_isLikelyNetworkError(uploadError) ||
              _isProjectRowMissingForSync(uploadError)) {
            await queueOfflineUpload();
          } else {
            rethrow;
          }
        }
      } else {
        await queueOfflineUpload();
      }

      if (mounted) {
        setState(() {
          if (resolvedLayoutId.isNotEmpty) {
            _layouts[layoutIndex]['id'] = resolvedLayoutId;
          }
          _layouts[layoutIndex]['layoutImageName'] = resolvedName;
          _layouts[layoutIndex]['layoutImagePath'] = storedPath;
          _layouts[layoutIndex]['layoutImageDocId'] = insertedDocId;
          _layouts[layoutIndex]['layoutImageExtension'] = resolvedExtension;
        });
      } else {
        if (resolvedLayoutId.isNotEmpty) {
          _layouts[layoutIndex]['id'] = resolvedLayoutId;
        }
        _layouts[layoutIndex]['layoutImageName'] = resolvedName;
        _layouts[layoutIndex]['layoutImagePath'] = storedPath;
        _layouts[layoutIndex]['layoutImageDocId'] = insertedDocId;
        _layouts[layoutIndex]['layoutImageExtension'] = resolvedExtension;
      }

      if (resolvedLayoutId.isNotEmpty) {
        await _persistLayoutImageMetaToLayout(
          layoutId: resolvedLayoutId,
          imageName: resolvedName,
          imagePath: storedPath,
          imageDocId: insertedDocId,
          imageExtension: resolvedExtension,
        );
      }
      await _saveLayoutsData(immediate: true);
      _setSaveStatus(queuedOfflineUpload
          ? ProjectSaveStatusType.queuedOffline
          : ProjectSaveStatusType.saved);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              queuedOfflineUpload
                  ? 'Saved in your system. Layout image queued for upload.'
                  : 'Uploaded to Documents > Layouts',
            ),
          ),
        );
      }
    } catch (e) {
      _setSaveStatus(ProjectSaveStatusType.connectionLost);
      final uploadedName =
          layoutIndex >= 0 && layoutIndex < _layouts.length && mounted
              ? (_layouts[layoutIndex]['layoutImageName'] ?? '').toString()
              : '';
      final errorText = _buildLayoutImageUploadErrorMessage(
        e,
        fileName: uploadedName.isEmpty ? debugFileName : uploadedName,
        fileSizeBytes: debugFileSizeBytes,
        contentType: debugContentType,
        storagePath: debugStoragePath,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorText)),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _layoutImageUploadInProgress.remove(layoutIndex);
        });
      } else {
        _layoutImageUploadInProgress.remove(layoutIndex);
      }
    }
  }

  Future<void> _openLayoutDocumentForLayout(int layoutIndex) async {
    if (layoutIndex < 0 || layoutIndex >= _layouts.length) return;

    try {
      final projectId = widget.projectId?.trim();
      if (projectId == null || projectId.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please save project first.')),
          );
        }
        return;
      }

      String storagePath =
          (_layouts[layoutIndex]['layoutImagePath'] ?? '').toString().trim();
      String docId =
          (_layouts[layoutIndex]['layoutImageDocId'] ?? '').toString().trim();
      String fileName =
          (_layouts[layoutIndex]['layoutImageName'] ?? '').toString().trim();
      String extension = (_layouts[layoutIndex]['layoutImageExtension'] ?? '')
          .toString()
          .trim();

      if (docId.isNotEmpty) {
        final byId = await _supabase
            .from('documents')
            .select('id,file_url,extension,name')
            .eq('id', docId)
            .maybeSingle();
        if (byId != null) {
          final latestStoragePath = (byId['file_url'] ?? '').toString().trim();
          if (latestStoragePath.isNotEmpty) {
            storagePath = latestStoragePath;
            docId = (byId['id'] ?? docId).toString().trim();
            fileName = (byId['name'] ?? fileName).toString().trim();
            extension = (byId['extension'] ?? extension).toString().trim();
          }
        }
      }

      if (storagePath.isEmpty) {
        final layoutId = await _resolveLayoutIdForDocument(layoutIndex);
        if (layoutId != null && layoutId.isNotEmpty) {
          final latest = await _findLatestLayoutDocumentRow(
            projectId: projectId,
            layoutId: layoutId,
          );
          if (latest != null) {
            storagePath = (latest['file_url'] ?? '').toString().trim();
            docId = (latest['id'] ?? docId).toString().trim();
            fileName = (latest['name'] ?? fileName).toString().trim();
            extension = (latest['extension'] ?? extension).toString().trim();
          }
        }
      }

      if (storagePath.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No uploaded layout image found.')),
          );
        }
        return;
      }

      final normalizedStoragePath = _resolveDocumentStoragePath(storagePath);
      final finalUrl = await _resolveDocumentPublicUrl(normalizedStoragePath);
      if (finalUrl.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open the layout image.')),
          );
        }
        return;
      }

      if (mounted) {
        setState(() {
          _layouts[layoutIndex]['layoutImagePath'] = normalizedStoragePath;
          _layouts[layoutIndex]['layoutImageDocId'] = docId;
          _layouts[layoutIndex]['layoutImageName'] = fileName;
          _layouts[layoutIndex]['layoutImageExtension'] = extension;
        });
      } else {
        _layouts[layoutIndex]['layoutImagePath'] = normalizedStoragePath;
        _layouts[layoutIndex]['layoutImageDocId'] = docId;
        _layouts[layoutIndex]['layoutImageName'] = fileName;
        _layouts[layoutIndex]['layoutImageExtension'] = extension;
      }

      final resolvedLayoutId = await _resolveLayoutIdForDocument(layoutIndex);
      if (resolvedLayoutId != null && resolvedLayoutId.isNotEmpty) {
        await _persistLayoutImageMetaToLayout(
          layoutId: resolvedLayoutId,
          imageName: fileName,
          imagePath: normalizedStoragePath,
          imageDocId: docId,
          imageExtension: extension,
        );
      }

      final layoutName =
          (_layouts[layoutIndex]['name'] ?? 'Layout ${layoutIndex + 1}')
              .toString()
              .trim();
      if (!mounted) {
        if (kIsWeb) {
          html.window.open(finalUrl, '_blank', 'noopener,noreferrer');
        } else {
          await _openUrlExternally(finalUrl);
        }
        return;
      }
      _showLayoutImageViewerDialog(
        imageUrl: finalUrl,
        layoutName:
            layoutName.isEmpty ? 'Layout ${layoutIndex + 1}' : layoutName,
        layoutIndex: layoutIndex,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open layout image: $e')),
        );
      }
    }
  }

  Future<void> _uploadLayoutDocumentForAmenity() async {
    if (_isAmenityLayoutImageUploadInProgress) return;

    final projectId = widget.projectId?.trim();
    String debugFileName = 'unknown';
    int debugFileSizeBytes = 0;
    String debugContentType = 'unknown';
    String debugStoragePath = 'unknown';

    if (projectId == null || projectId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please save project first.')),
        );
      }
      return;
    }
    var canAttemptRemoteUpload = widget.isNetworkReachable;
    if (canAttemptRemoteUpload) {
      final remoteProjectReady =
          await ProjectStorageService.ensureRemoteProjectExistsForDocumentSync(
        projectId,
      );
      canAttemptRemoteUpload = remoteProjectReady;
    }

    if (mounted) {
      setState(() {
        _isAmenityLayoutImageUploadInProgress = true;
      });
    } else {
      _isAmenityLayoutImageUploadInProgress = true;
    }

    try {
      final file = await pickSingleLocalFile(
        allowedExtensions: const <String>[
          'png',
          'jpg',
          'jpeg',
          'webp',
          'gif',
        ],
      );
      if (file == null) return;
      _setSaveStatus(ProjectSaveStatusType.uploadingFile);

      final folderId = await _ensureAmenityDocumentsFolderId();
      if (folderId == null || folderId.isEmpty) {
        throw Exception('Could not create/find Amenity Area folder');
      }

      final fileName = file.name;
      final extension = _getLayoutImageExtension(fileName);
      final allowedImageExtensions = <String>{
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
      };
      if (!allowedImageExtensions.contains(extension)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Unsupported image format "$extension". Please upload PNG/JPG/WebP/GIF.',
              ),
            ),
          );
        }
        return;
      }

      final storageFileName = _sanitizeStorageFileName(fileName);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final storagePath = '$projectId/$folderId/$timestamp-$storageFileName';
      final contentType = file.mimeType.isEmpty
          ? _getLayoutImageContentType(extension)
          : file.mimeType;
      debugFileName = fileName;
      debugFileSizeBytes = file.sizeBytes;
      debugContentType = contentType;
      debugStoragePath = storagePath;
      final bytes = file.bytes;

      var queuedOfflineUpload = false;
      var insertedDocId = '';
      var storedPath = storagePath;
      var resolvedName = fileName;
      var resolvedExtension = extension;

      Future<void> queueOfflineUpload() async {
        await OfflineFileUploadQueueService.enqueueAmenityLayoutImageUpload(
          projectId: projectId,
          bytes: bytes,
          fileName: fileName,
          extension: extension,
          contentType: contentType,
          storagePath: storagePath,
          parentFolderId: folderId,
          fileSizeBytes: file.sizeBytes,
        );
        queuedOfflineUpload = true;
      }

      if (canAttemptRemoteUpload) {
        try {
          await _supabase.storage.from('documents').uploadBinary(
                storagePath,
                bytes,
                fileOptions: FileOptions(
                  contentType: contentType,
                  cacheControl: '3600',
                  upsert: false,
                ),
              );

          final insertedDoc = await _supabase
              .from('documents')
              .insert({
                'project_id': projectId,
                'name': fileName,
                'type': 'file',
                'extension': extension,
                'parent_id': folderId,
                'file_url': storagePath,
                'file_size': file.sizeBytes,
              })
              .select('id,extension,file_url,name')
              .maybeSingle();

          insertedDocId = (insertedDoc?['id'] ?? '').toString().trim();
          storedPath =
              (insertedDoc?['file_url'] ?? storagePath).toString().trim();
          resolvedName = (insertedDoc?['name'] ?? fileName).toString().trim();
          resolvedExtension =
              (insertedDoc?['extension'] ?? extension).toString().trim();
        } catch (uploadError) {
          if (_isLikelyNetworkError(uploadError) ||
              _isProjectRowMissingForSync(uploadError)) {
            await queueOfflineUpload();
          } else {
            rethrow;
          }
        }
      } else {
        await queueOfflineUpload();
      }

      if (mounted) {
        setState(() {
          _amenityLayoutImageName = resolvedName;
          _amenityLayoutImagePath = storedPath;
          _amenityLayoutImageDocId = insertedDocId;
          _amenityLayoutImageExtension = resolvedExtension;
        });
      } else {
        _amenityLayoutImageName = resolvedName;
        _amenityLayoutImagePath = storedPath;
        _amenityLayoutImageDocId = insertedDocId;
        _amenityLayoutImageExtension = resolvedExtension;
      }

      await _persistAmenityLayoutImageMetaToProject(
        imageName: resolvedName,
        imagePath: storedPath,
        imageDocId: insertedDocId,
        imageExtension: resolvedExtension,
      );
      _setSaveStatus(queuedOfflineUpload
          ? ProjectSaveStatusType.queuedOffline
          : ProjectSaveStatusType.saved);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              queuedOfflineUpload
                  ? 'Saved in your system. Amenity image queued for upload.'
                  : 'Uploaded to Documents > Amenity Area',
            ),
          ),
        );
      }
    } catch (e) {
      _setSaveStatus(ProjectSaveStatusType.connectionLost);
      final uploadedName = _amenityLayoutImageName.trim();
      final errorText = _buildLayoutImageUploadErrorMessage(
        e,
        fileName: uploadedName.isEmpty ? debugFileName : uploadedName,
        fileSizeBytes: debugFileSizeBytes,
        contentType: debugContentType,
        storagePath: debugStoragePath,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorText)),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isAmenityLayoutImageUploadInProgress = false;
        });
      } else {
        _isAmenityLayoutImageUploadInProgress = false;
      }
    }
  }

  Future<void> _openLayoutDocumentForAmenity() async {
    try {
      final projectId = widget.projectId?.trim();
      if (projectId == null || projectId.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please save project first.')),
          );
        }
        return;
      }

      String storagePath = _amenityLayoutImagePath.trim();
      String docId = _amenityLayoutImageDocId.trim();
      String fileName = _amenityLayoutImageName.trim();
      String extension = _amenityLayoutImageExtension.trim();

      if (docId.isNotEmpty) {
        final byId = await _supabase
            .from('documents')
            .select('id,file_url,extension,name')
            .eq('id', docId)
            .maybeSingle();
        if (byId != null) {
          final latestStoragePath = (byId['file_url'] ?? '').toString().trim();
          if (latestStoragePath.isNotEmpty) {
            storagePath = latestStoragePath;
            docId = (byId['id'] ?? docId).toString().trim();
            fileName = (byId['name'] ?? fileName).toString().trim();
            extension = (byId['extension'] ?? extension).toString().trim();
          }
        }
      }

      if (storagePath.isEmpty) {
        final folderId =
            await _findRootDocumentsFolderIdByName(_amenityDocumentsFolderName);
        if (folderId != null && folderId.isNotEmpty) {
          final latest = await _findLatestAmenityLayoutDocumentRow(
            projectId: projectId,
            folderId: folderId,
          );
          if (latest != null) {
            storagePath = (latest['file_url'] ?? '').toString().trim();
            docId = (latest['id'] ?? docId).toString().trim();
            fileName = (latest['name'] ?? fileName).toString().trim();
            extension = (latest['extension'] ?? extension).toString().trim();
          }
        }
      }

      if (storagePath.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No uploaded layout image found.')),
          );
        }
        return;
      }

      final normalizedStoragePath = _resolveDocumentStoragePath(storagePath);
      final finalUrl = await _resolveDocumentPublicUrl(normalizedStoragePath);
      if (finalUrl.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open the layout image.')),
          );
        }
        return;
      }

      if (mounted) {
        setState(() {
          _amenityLayoutImagePath = normalizedStoragePath;
          _amenityLayoutImageDocId = docId;
          _amenityLayoutImageName = fileName;
          _amenityLayoutImageExtension = extension;
        });
      } else {
        _amenityLayoutImagePath = normalizedStoragePath;
        _amenityLayoutImageDocId = docId;
        _amenityLayoutImageName = fileName;
        _amenityLayoutImageExtension = extension;
      }

      await _persistAmenityLayoutImageMetaToProject(
        imageName: fileName,
        imagePath: normalizedStoragePath,
        imageDocId: docId,
        imageExtension: extension,
      );

      if (!mounted) {
        if (kIsWeb) {
          html.window.open(finalUrl, '_blank', 'noopener,noreferrer');
        } else {
          await _openUrlExternally(finalUrl);
        }
        return;
      }
      _showLayoutImageViewerDialog(
        imageUrl: finalUrl,
        layoutName: 'Amenity Area',
        isAmenityImage: true,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open layout image: $e')),
        );
      }
    }
  }

  void _showLayoutImageViewerDialog({
    required String imageUrl,
    required String layoutName,
    int? layoutIndex,
    bool isAmenityImage = false,
  }) {
    if (!mounted) return;

    final viewerController = TransformationController();
    final strokes = <_LayoutViewerStroke>[];
    int? activeStrokeIndex;
    int? activePointerId;
    var isPenModeActive = true;
    var isEraserModeActive = false;
    var isPanModeActive = false;
    var isThicknessPickerVisible = false;
    var isThicknessPickerForEraser = false;
    var isColorPickerVisible = false;
    var selectedThicknessIndex = 1;
    var selectedEraserThicknessIndex = 1;
    var selectedColorIndex = 0;
    var lastCanvasSize = Size.zero;
    var lastImageContentSize = Size.zero;
    var imageNaturalSize = Size.zero;
    var requestedImageNaturalSize = false;
    var hasPendingEdits = false;
    var isPersistingEdits = false;
    var skipPersistOnClose = false;
    var isDeletingImage = false;

    void markEditsDirty() {
      hasPendingEdits = true;
    }

    List<_LayoutViewerStroke> cloneStrokes() {
      return strokes
          .map(
            (stroke) => _LayoutViewerStroke(
              normalizedPoints: List<Offset>.from(stroke.normalizedPoints),
              color: stroke.color,
              thickness: stroke.thickness,
            ),
          )
          .toList(growable: false);
    }

    Offset? scenePositionFromLocal({
      required Offset localPosition,
      required Size canvasSize,
      bool clampToBounds = false,
    }) {
      if (canvasSize.width <= 0 || canvasSize.height <= 0) return null;
      Offset scenePosition = viewerController.toScene(localPosition);
      if (clampToBounds) {
        scenePosition = Offset(
          scenePosition.dx.clamp(0.0, canvasSize.width),
          scenePosition.dy.clamp(0.0, canvasSize.height),
        );
        return scenePosition;
      }
      if (scenePosition.dx < 0 ||
          scenePosition.dy < 0 ||
          scenePosition.dx > canvasSize.width ||
          scenePosition.dy > canvasSize.height) {
        return null;
      }
      return scenePosition;
    }

    Rect imageContentRectForCanvas(Size canvasSize) {
      if (canvasSize.width <= 0 || canvasSize.height <= 0) {
        return Rect.zero;
      }
      if (imageNaturalSize.width <= 0 || imageNaturalSize.height <= 0) {
        return Offset.zero & canvasSize;
      }
      final imageAspect = imageNaturalSize.width / imageNaturalSize.height;
      final canvasAspect = canvasSize.width / canvasSize.height;
      if (imageAspect > canvasAspect) {
        final width = canvasSize.width;
        final height = width / imageAspect;
        final top = (canvasSize.height - height) / 2;
        return Rect.fromLTWH(0, top, width, height);
      }
      final height = canvasSize.height;
      final width = height * imageAspect;
      final left = (canvasSize.width - width) / 2;
      return Rect.fromLTWH(left, 0, width, height);
    }

    Offset? normalizedImagePointFromLocal({
      required Offset localPosition,
      required Size canvasSize,
      bool clampToBounds = false,
    }) {
      final scenePosition = scenePositionFromLocal(
        localPosition: localPosition,
        canvasSize: canvasSize,
        clampToBounds: true,
      );
      if (scenePosition == null) return null;
      final imageRect = imageContentRectForCanvas(canvasSize);
      if (imageRect.width <= 0 || imageRect.height <= 0) return null;

      Offset mappedPosition = scenePosition;
      if (clampToBounds) {
        mappedPosition = Offset(
          mappedPosition.dx.clamp(imageRect.left, imageRect.right),
          mappedPosition.dy.clamp(imageRect.top, imageRect.bottom),
        );
      } else if (!imageRect.contains(mappedPosition)) {
        return null;
      }

      final nx = (mappedPosition.dx - imageRect.left) / imageRect.width;
      final ny = (mappedPosition.dy - imageRect.top) / imageRect.height;
      return Offset(nx.clamp(0.0, 1.0), ny.clamp(0.0, 1.0));
    }

    Future<void> persistEditsIfNeeded() async {
      if (skipPersistOnClose ||
          isPersistingEdits ||
          !hasPendingEdits ||
          strokes.isEmpty) {
        return;
      }
      if (lastCanvasSize.width <= 0 || lastCanvasSize.height <= 0) {
        return;
      }

      isPersistingEdits = true;
      try {
        if (isAmenityImage) {
          await _savePlotStatusAmenityLayoutViewerEdits(
            strokes: cloneStrokes(),
            drawingCanvasSize: lastCanvasSize,
            drawingImageSize: lastImageContentSize,
          );
        } else if (layoutIndex != null) {
          await _savePlotStatusLayoutViewerEdits(
            layoutIndex: layoutIndex,
            strokes: cloneStrokes(),
            drawingCanvasSize: lastCanvasSize,
            drawingImageSize: lastImageContentSize,
          );
        }
        hasPendingEdits = false;
      } catch (e, st) {
        print('PlotStatusPage: Failed to save layout edits: $e');
        print(st);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to save layout edits: $e')),
          );
        }
      } finally {
        isPersistingEdits = false;
      }
    }

    Future<void> deleteLayoutImageAndMetadata() async {
      final projectId = widget.projectId?.trim();
      if (projectId == null || projectId.isEmpty) return;

      String storagePath = '';
      String docId = '';
      String parentFolderId = '';
      if (isAmenityImage) {
        storagePath = _resolveDocumentStoragePath(_amenityLayoutImagePath);
        docId = _amenityLayoutImageDocId.trim();
      } else if (layoutIndex != null &&
          layoutIndex >= 0 &&
          layoutIndex < _layouts.length) {
        storagePath = _resolveDocumentStoragePath(
          (_layouts[layoutIndex]['layoutImagePath'] ?? '').toString(),
        );
        docId =
            (_layouts[layoutIndex]['layoutImageDocId'] ?? '').toString().trim();
      }

      final resolved = await _resolveDocumentDeletionTargets(
        projectId: projectId,
        docId: docId,
        urlOrPath: storagePath,
      );
      storagePath = resolved['storagePath'] ?? '';
      docId = resolved['docId'] ?? '';
      parentFolderId = resolved['parentFolderId'] ?? '';

      if (storagePath.isNotEmpty) {
        try {
          await _supabase.storage.from('documents').remove([storagePath]);
        } catch (_) {}
      }

      if (docId.isNotEmpty) {
        await _supabase.from('documents').delete().eq('id', docId);
      } else if (storagePath.isNotEmpty) {
        await _supabase
            .from('documents')
            .delete()
            .eq('project_id', projectId)
            .eq('file_url', storagePath);
      }

      await _deleteLayoutChildFolderIfEmpty(
        projectId: projectId,
        folderId: parentFolderId,
      );

      if (isAmenityImage) {
        if (mounted) {
          setState(() {
            _amenityLayoutImageName = '';
            _amenityLayoutImagePath = '';
            _amenityLayoutImageDocId = '';
            _amenityLayoutImageExtension = '';
          });
        } else {
          _amenityLayoutImageName = '';
          _amenityLayoutImagePath = '';
          _amenityLayoutImageDocId = '';
          _amenityLayoutImageExtension = '';
        }
        await _persistAmenityLayoutImageMetaToProject(
          imageName: '',
          imagePath: '',
          imageDocId: '',
          imageExtension: '',
        );
      } else if (layoutIndex != null &&
          layoutIndex >= 0 &&
          layoutIndex < _layouts.length) {
        if (mounted) {
          setState(() {
            _layouts[layoutIndex]['layoutImageName'] = '';
            _layouts[layoutIndex]['layoutImagePath'] = '';
            _layouts[layoutIndex]['layoutImageDocId'] = '';
            _layouts[layoutIndex]['layoutImageExtension'] = '';
          });
        } else {
          _layouts[layoutIndex]['layoutImageName'] = '';
          _layouts[layoutIndex]['layoutImagePath'] = '';
          _layouts[layoutIndex]['layoutImageDocId'] = '';
          _layouts[layoutIndex]['layoutImageExtension'] = '';
        }
        await _saveLayoutsData(immediate: true);
        final resolvedLayoutId = await _resolveLayoutIdForDocument(layoutIndex);
        if (resolvedLayoutId != null && resolvedLayoutId.isNotEmpty) {
          await _persistLayoutImageMetaToLayout(
            layoutId: resolvedLayoutId,
            imageName: '',
            imagePath: '',
            imageDocId: '',
            imageExtension: '',
          );
        }
      }
    }

    void zoomByStep(double delta) {
      final matrix = viewerController.value.clone();
      final currentScale = matrix.getMaxScaleOnAxis();
      final targetScale = (currentScale + delta).clamp(1.0, 4.0);
      if ((targetScale - currentScale).abs() < 0.0001) {
        return;
      }
      // Keep original size as the minimum zoom and re-center when returning to it.
      if (targetScale <= 1.0001) {
        viewerController.value = Matrix4.identity();
        return;
      }
      final scaleFactor = targetScale / currentScale;
      if (lastCanvasSize.width > 0 && lastCanvasSize.height > 0) {
        final focalPoint =
            Offset(lastCanvasSize.width / 2, lastCanvasSize.height / 2);
        final sceneFocal = viewerController.toScene(focalPoint);
        matrix.translate(sceneFocal.dx, sceneFocal.dy);
        matrix.scale(scaleFactor);
        matrix.translate(-sceneFocal.dx, -sceneFocal.dy);
      } else {
        matrix.scale(scaleFactor);
      }
      viewerController.value = matrix;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (dialogContext) {
        final screenSize = MediaQuery.of(dialogContext).size;
        const viewportPadding = 24.0;
        const maxViewerWidth = 1175.0; // 1080 image + 20 gap + 75 rail
        const maxViewerHeight = 970.0; // site-section viewer stack max height
        final dialogWidth = (screenSize.width - (viewportPadding * 2))
            .clamp(620.0, maxViewerWidth);
        final dialogHeight = (screenSize.height - (viewportPadding * 2))
            .clamp(420.0, maxViewerHeight);

        return StatefulBuilder(
          builder: (context, setDialogState) {
            const baseOptionWidth = 75.0;
            const baseOptionHeight = 73.0;
            const baseOptionGap = 12.0;
            const baseCloseIconSize = 42.0;
            const baseCloseToToolsGap = 63.0;
            const baseBottomActionsGap = 24.0;
            const toolCount = 9;
            const railGapFromImage = 20.0;
            const panelWidth = 95.0;

            if (!requestedImageNaturalSize) {
              requestedImageNaturalSize = true;
              unawaited(
                _fetchImageNaturalSizeFromUrl(imageUrl).then((size) {
                  if (!dialogContext.mounted) return;
                  if (size.width <= 0 || size.height <= 0) return;
                  setDialogState(() {
                    imageNaturalSize = size;
                  });
                }).catchError((_) {}),
              );
            }

            void closeToolPickers() {
              setDialogState(() {
                isThicknessPickerVisible = false;
                isThicknessPickerForEraser = false;
                isColorPickerVisible = false;
              });
            }

            void setThicknessPickerVisible(bool visible,
                {bool forEraser = false}) {
              setDialogState(() {
                isThicknessPickerVisible = visible;
                if (visible) {
                  isThicknessPickerForEraser = forEraser;
                  isColorPickerVisible = false;
                } else {
                  isThicknessPickerForEraser = false;
                }
              });
            }

            void setColorPickerVisible(bool visible) {
              setDialogState(() {
                isColorPickerVisible = visible;
                if (visible) {
                  isThicknessPickerVisible = false;
                  isThicknessPickerForEraser = false;
                }
              });
            }

            void eraseAt({
              required Offset localPosition,
              required Size canvasSize,
            }) {
              if (!isEraserModeActive) return;
              final normalizedTouch = normalizedImagePointFromLocal(
                localPosition: localPosition,
                canvasSize: canvasSize,
                clampToBounds: true,
              );
              final imageSize = imageContentRectForCanvas(canvasSize).size;
              if (normalizedTouch == null ||
                  imageSize.width <= 0 ||
                  imageSize.height <= 0 ||
                  strokes.isEmpty) {
                return;
              }

              final eraserThickness =
                  _layoutThicknessOptions[selectedEraserThicknessIndex];
              final eraserRadiusPx =
                  (eraserThickness * 8.0) < 8.0 ? 8.0 : eraserThickness * 8.0;
              final eraserRadiusSq = eraserRadiusPx * eraserRadiusPx;
              final touchX = normalizedTouch.dx * imageSize.width;
              final touchY = normalizedTouch.dy * imageSize.height;

              final updated = <_LayoutViewerStroke>[];
              var changed = false;

              for (final stroke in strokes) {
                if (stroke.normalizedPoints.isEmpty) continue;

                final segments = <List<Offset>>[];
                var current = <Offset>[];
                var strokeChanged = false;

                for (final point in stroke.normalizedPoints) {
                  final dx = (point.dx * imageSize.width) - touchX;
                  final dy = (point.dy * imageSize.height) - touchY;
                  final shouldErase = (dx * dx) + (dy * dy) <= eraserRadiusSq;

                  if (shouldErase) {
                    strokeChanged = true;
                    if (current.isNotEmpty) {
                      segments.add(current);
                      current = <Offset>[];
                    }
                    continue;
                  }
                  current.add(point);
                }

                if (current.isNotEmpty) {
                  segments.add(current);
                }

                if (!strokeChanged) {
                  updated.add(stroke);
                  continue;
                }

                changed = true;
                for (final segment in segments) {
                  if (segment.isEmpty) continue;
                  updated.add(
                    _LayoutViewerStroke(
                      normalizedPoints: List<Offset>.from(segment),
                      color: stroke.color,
                      thickness: stroke.thickness,
                    ),
                  );
                }
              }

              if (!changed) return;
              setDialogState(() {
                strokes
                  ..clear()
                  ..addAll(updated);
                hasPendingEdits = true;
              });
            }

            void beginStroke({
              required Offset localPosition,
              required Size canvasSize,
            }) {
              if (!isPenModeActive) return;
              final normalizedPoint = normalizedImagePointFromLocal(
                localPosition: localPosition,
                canvasSize: canvasSize,
              );
              if (normalizedPoint == null) return;

              final selectedColor =
                  _layoutColorOptions[selectedColorIndex].withOpacity(0.5);
              final selectedThickness =
                  _layoutThicknessOptions[selectedThicknessIndex];

              setDialogState(() {
                strokes.add(
                  _LayoutViewerStroke(
                    normalizedPoints: <Offset>[normalizedPoint],
                    color: selectedColor,
                    thickness: selectedThickness,
                  ),
                );
                activeStrokeIndex = strokes.length - 1;
              });
              markEditsDirty();
            }

            void appendStrokePoint({
              required Offset localPosition,
              required Size canvasSize,
            }) {
              if (!isPenModeActive) return;
              if (activeStrokeIndex == null ||
                  activeStrokeIndex! < 0 ||
                  activeStrokeIndex! >= strokes.length) {
                beginStroke(
                  localPosition: localPosition,
                  canvasSize: canvasSize,
                );
                return;
              }

              final normalizedPoint = normalizedImagePointFromLocal(
                localPosition: localPosition,
                canvasSize: canvasSize,
                clampToBounds: true,
              );
              if (normalizedPoint == null) return;
              final imageSize = imageContentRectForCanvas(canvasSize).size;
              if (imageSize.width <= 0 || imageSize.height <= 0) return;

              final points = strokes[activeStrokeIndex!].normalizedPoints;
              if (points.isNotEmpty) {
                final last = points.last;
                final dx = (normalizedPoint.dx - last.dx) * imageSize.width;
                final dy = (normalizedPoint.dy - last.dy) * imageSize.height;
                if ((dx * dx) + (dy * dy) < 0.25) {
                  return;
                }
              }

              setDialogState(() {
                points.add(normalizedPoint);
              });
              markEditsDirty();
            }

            void togglePenMode() {
              setDialogState(() {
                isPenModeActive = !isPenModeActive;
                if (isPenModeActive) {
                  isEraserModeActive = false;
                  isPanModeActive = false;
                }
                if (!isPenModeActive) {
                  activeStrokeIndex = null;
                  activePointerId = null;
                }
              });
            }

            void activatePanMode() {
              setDialogState(() {
                isPanModeActive = true;
                isPenModeActive = false;
                isEraserModeActive = false;
                activeStrokeIndex = null;
                activePointerId = null;
              });
            }

            void activateEraserMode() {
              setDialogState(() {
                isEraserModeActive = true;
                isPenModeActive = false;
                isPanModeActive = false;
                activeStrokeIndex = null;
                activePointerId = null;
              });
            }

            Future<_LayoutViewerCloseDecision?> showUnsavedEditsDialog() async {
              var isSaving = false;
              final result = await showDialog<_LayoutViewerCloseDecision>(
                context: dialogContext,
                barrierDismissible: true,
                barrierColor: Colors.black.withOpacity(0.5),
                builder: (popupContext) {
                  return StatefulBuilder(
                    builder: (context, setPopupState) => Material(
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
                                    color: Colors.black.withOpacity(0.25),
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
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'Changes may not be saved',
                                        style: GoogleFonts.inter(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.black,
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () {
                                          if (isSaving) return;
                                          Navigator.of(popupContext).pop(null);
                                        },
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
                                    'You have unsaved changes on this layout image.',
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: Colors.black.withOpacity(0.8),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Save before closing?',
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: Colors.black.withOpacity(0.8),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      GestureDetector(
                                        onTap: () {
                                          if (isSaving) return;
                                          Navigator.of(popupContext).pop(
                                            _LayoutViewerCloseDecision.discard,
                                          );
                                        },
                                        child: Container(
                                          height: 44,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 4),
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
                                              ),
                                            ],
                                          ),
                                          child: Center(
                                            child: Text(
                                              'Discard',
                                              style: GoogleFonts.inter(
                                                fontSize: 14,
                                                fontWeight: FontWeight.normal,
                                                color: const Color(0xFFD32F2F),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () async {
                                          if (isSaving) return;
                                          setPopupState(() => isSaving = true);
                                          await persistEditsIfNeeded();
                                          if (!hasPendingEdits) {
                                            if (popupContext.mounted) {
                                              Navigator.of(popupContext).pop(
                                                _LayoutViewerCloseDecision.save,
                                              );
                                            }
                                            return;
                                          }
                                          if (popupContext.mounted) {
                                            setPopupState(
                                                () => isSaving = false);
                                          }
                                        },
                                        child: Container(
                                          height: 44,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 4),
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
                                              ),
                                            ],
                                          ),
                                          child: Center(
                                            child: isSaving
                                                ? const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                              Color>(
                                                        Color(0xFF0C8CE9),
                                                      ),
                                                    ),
                                                  )
                                                : Text(
                                                    'Save',
                                                    style: GoogleFonts.inter(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.normal,
                                                      color: const Color(
                                                          0xFF0C8CE9),
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
                    ),
                  );
                },
              );
              return result;
            }

            Future<bool> showDeleteImageDialog() async {
              final currentLayoutName = isAmenityImage
                  ? 'Amenity Area'
                  : layoutName.trim().isEmpty
                      ? 'NA'
                      : layoutName.trim();
              final layoutNumberPrefix =
                  !isAmenityImage && layoutIndex != null && layoutIndex >= 0
                      ? '${layoutIndex + 1}. Layout:'
                      : 'Layout:';
              var isDeleting = false;
              final result = await showDialog<bool>(
                context: dialogContext,
                barrierDismissible: true,
                barrierColor: Colors.black.withOpacity(0.5),
                builder: (popupContext) {
                  return StatefulBuilder(
                    builder: (_, setPopupState) => Material(
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
                                    color: Colors.black.withOpacity(0.25),
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
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'Delete Layout Image?',
                                        style: GoogleFonts.inter(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.black,
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () {
                                          if (isDeleting) return;
                                          Navigator.of(popupContext).pop(false);
                                        },
                                        child: const Icon(
                                          Icons.close,
                                          size: 22,
                                          color: Color(0xFF0C8CE9),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  RichText(
                                    text: TextSpan(
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.normal,
                                        color: Colors.black.withOpacity(0.8),
                                      ),
                                      children: [
                                        TextSpan(
                                          text: layoutNumberPrefix,
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color:
                                                Colors.black.withOpacity(0.8),
                                          ),
                                        ),
                                        TextSpan(text: ' $currentLayoutName'),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'This will permanently delete this layout Image',
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: Colors.black.withOpacity(0.8),
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
                                  const SizedBox(height: 16),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      GestureDetector(
                                        onTap: () {
                                          if (isDeleting) return;
                                          Navigator.of(popupContext).pop(false);
                                        },
                                        child: Container(
                                          height: 44,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 4),
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
                                          if (isDeleting) return;
                                          setPopupState(
                                              () => isDeleting = true);
                                          await Future<void>.delayed(
                                            const Duration(milliseconds: 250),
                                          );
                                          if (popupContext.mounted) {
                                            Navigator.of(popupContext)
                                                .pop(true);
                                          }
                                        },
                                        child: Container(
                                          height: 44,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 4),
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
                                              ),
                                            ],
                                          ),
                                          child: Center(
                                            child: isDeleting
                                                ? const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                              Color>(
                                                        Color(0xFFFF0000),
                                                      ),
                                                    ),
                                                  )
                                                : Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text(
                                                        'Delete Image',
                                                        style:
                                                            GoogleFonts.inter(
                                                          fontSize: 14,
                                                          fontWeight:
                                                              FontWeight.normal,
                                                          color: const Color(
                                                              0xFFFF0000),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      SvgPicture.asset(
                                                        'assets/images/Delete_layout.svg',
                                                        width: 13,
                                                        height: 16,
                                                        fit: BoxFit.contain,
                                                      ),
                                                    ],
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
                    ),
                  );
                },
              );
              return result ?? false;
            }

            return Center(
              child: SizedBox(
                width: dialogWidth,
                height: dialogHeight,
                child: LayoutBuilder(
                  builder: (context, contentConstraints) {
                    const baseImageBoxWidth = 1080.0;
                    const baseImageBoxHeight = 768.0;
                    const baseCloseIconGapToPen = 63.0;
                    const thicknessPanelWidth = 91.0;
                    const thicknessPanelTopOffset = 0.0;
                    const thicknessPanelRightShift = 4.0;
                    const thicknessIconExtraWidth = 8.0;
                    const baseBottomActionIconGap = 35.0;
                    const baseBottomActionTopGap = 24.0;

                    final availableWidth = contentConstraints.maxWidth
                        .clamp(200.0, double.infinity);
                    final availableHeight = contentConstraints.maxHeight
                        .clamp(200.0, double.infinity);
                    final mainAreaAvailableHeight = math.max(
                      200.0,
                      availableHeight -
                          (baseCloseIconSize + baseCloseIconGapToPen) -
                          baseBottomActionTopGap -
                          baseOptionHeight,
                    );
                    final maxImageWidth = math.max(
                      200.0,
                      availableWidth - railGapFromImage - baseOptionWidth,
                    );
                    final scale = math.min(
                      1.0,
                      math.min(
                        maxImageWidth / baseImageBoxWidth,
                        mainAreaAvailableHeight / baseImageBoxHeight,
                      ),
                    );
                    final imageBoxWidth = baseImageBoxWidth * scale;
                    final imageBoxHeight = baseImageBoxHeight * scale;
                    lastCanvasSize = Size(imageBoxWidth, imageBoxHeight);
                    lastImageContentSize =
                        imageContentRectForCanvas(lastCanvasSize).size;
                    final baseSideRailHeight = baseCloseIconSize +
                        baseCloseIconGapToPen +
                        (baseOptionHeight * toolCount) +
                        (baseOptionGap * (toolCount - 1));
                    final sideToolScale =
                        math.min(1.0, imageBoxHeight / baseSideRailHeight);
                    final optionWidth = baseOptionWidth * sideToolScale;
                    final optionHeight = baseOptionHeight * sideToolScale;
                    final optionGap = baseOptionGap * sideToolScale;
                    final closeIconSize = baseCloseIconSize * sideToolScale;
                    final closeIconGapToPen =
                        baseCloseIconGapToPen * sideToolScale;
                    final bottomActionIconWidth = optionWidth;
                    final bottomActionIconHeight = optionHeight;
                    final bottomActionIconGap =
                        baseBottomActionIconGap * sideToolScale;
                    final bottomActionTopGap =
                        baseBottomActionTopGap * sideToolScale;
                    final thicknessIconExpandedWidth =
                        optionWidth + (thicknessIconExtraWidth * sideToolScale);
                    final railBaseHeight = (optionHeight * toolCount) +
                        (optionGap * (toolCount - 1));
                    final closeTopInset = closeIconSize + closeIconGapToPen;
                    final viewerMainHeight =
                        math.max(imageBoxHeight, railBaseHeight);
                    final viewerHeight = closeTopInset +
                        viewerMainHeight +
                        bottomActionTopGap +
                        bottomActionIconHeight;
                    final railTopInset =
                        (viewerMainHeight - railBaseHeight) / 2;
                    final imageTopInset =
                        math.max(0.0, (viewerMainHeight - imageBoxHeight) / 2);
                    double toolTop(int toolIndex) =>
                        closeTopInset +
                        railTopInset +
                        ((optionHeight + optionGap) * toolIndex);
                    final closeIconRightInset =
                        (optionWidth - closeIconSize) / 2;

                    return Center(
                      child: GestureDetector(
                        onTap: () {},
                        child: SizedBox(
                          width: imageBoxWidth + railGapFromImage + optionWidth,
                          height: viewerHeight,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                top: closeTopInset,
                                left: 0,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: closeToolPickers,
                                      child: Container(
                                        width: imageBoxWidth,
                                        height: imageBoxHeight,
                                        clipBehavior: Clip.hardEdge,
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Listener(
                                          behavior: HitTestBehavior.opaque,
                                          onPointerDown: (details) {
                                            closeToolPickers();
                                            final canvasSize = Size(
                                                imageBoxWidth, imageBoxHeight);
                                            lastCanvasSize = canvasSize;
                                            lastImageContentSize =
                                                imageContentRectForCanvas(
                                                        canvasSize)
                                                    .size;
                                            activePointerId = details.pointer;
                                            if (isPenModeActive) {
                                              beginStroke(
                                                localPosition:
                                                    details.localPosition,
                                                canvasSize: canvasSize,
                                              );
                                            } else if (isEraserModeActive) {
                                              eraseAt(
                                                localPosition:
                                                    details.localPosition,
                                                canvasSize: canvasSize,
                                              );
                                            }
                                          },
                                          onPointerMove: (details) {
                                            final canvasSize = Size(
                                                imageBoxWidth, imageBoxHeight);
                                            lastCanvasSize = canvasSize;
                                            lastImageContentSize =
                                                imageContentRectForCanvas(
                                                        canvasSize)
                                                    .size;
                                            if (activePointerId !=
                                                details.pointer) {
                                              return;
                                            }
                                            if (isPenModeActive) {
                                              appendStrokePoint(
                                                localPosition:
                                                    details.localPosition,
                                                canvasSize: canvasSize,
                                              );
                                            } else if (isEraserModeActive) {
                                              eraseAt(
                                                localPosition:
                                                    details.localPosition,
                                                canvasSize: canvasSize,
                                              );
                                            }
                                          },
                                          onPointerUp: (details) {
                                            if (activePointerId !=
                                                details.pointer) {
                                              return;
                                            }
                                            activePointerId = null;
                                            activeStrokeIndex = null;
                                          },
                                          onPointerCancel: (details) {
                                            if (activePointerId !=
                                                details.pointer) {
                                              return;
                                            }
                                            activePointerId = null;
                                            activeStrokeIndex = null;
                                          },
                                          child: InteractiveViewer(
                                            transformationController:
                                                viewerController,
                                            minScale: 1.0,
                                            maxScale: 4.0,
                                            panEnabled: isPanModeActive,
                                            scaleEnabled: isPanModeActive,
                                            onInteractionEnd: (_) {
                                              final scale = viewerController
                                                  .value
                                                  .getMaxScaleOnAxis();
                                              if (scale <= 1.0001) {
                                                viewerController.value =
                                                    Matrix4.identity();
                                              }
                                            },
                                            clipBehavior: Clip.hardEdge,
                                            child: SizedBox(
                                              width: imageBoxWidth,
                                              height: imageBoxHeight,
                                              child: Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  Image.network(
                                                    imageUrl,
                                                    fit: BoxFit.contain,
                                                    alignment: Alignment.center,
                                                    frameBuilder: (
                                                      context,
                                                      child,
                                                      frame,
                                                      wasSynchronouslyLoaded,
                                                    ) {
                                                      if (wasSynchronouslyLoaded ||
                                                          frame != null) {
                                                        return child;
                                                      }
                                                      return Container(
                                                        color: Colors.white,
                                                        child: const Center(
                                                          child: SizedBox(
                                                            width: 28,
                                                            height: 28,
                                                            child:
                                                                CircularProgressIndicator(
                                                              strokeWidth: 2.5,
                                                              color: Color(
                                                                  0xFF0C8CE9),
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                    loadingBuilder: (context,
                                                        child,
                                                        loadingProgress) {
                                                      return child;
                                                    },
                                                    errorBuilder: (
                                                      context,
                                                      error,
                                                      stackTrace,
                                                    ) {
                                                      return Center(
                                                        child: Text(
                                                          'Unable to load layout image.',
                                                          style:
                                                              GoogleFonts.inter(
                                                            fontSize: 16,
                                                            fontWeight:
                                                                FontWeight.w500,
                                                            color: Colors.black,
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                  IgnorePointer(
                                                    child: CustomPaint(
                                                      painter:
                                                          _LayoutViewerStrokesPainter(
                                                        strokes: strokes,
                                                        imageNaturalSize:
                                                            imageNaturalSize,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(width: railGapFromImage),
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _buildLayoutImageViewerToolButton(
                                          iconAssetPath: isPenModeActive
                                              ? 'assets/images/Pen_active.svg'
                                              : 'assets/images/Pen.svg',
                                          onTap: () {
                                            closeToolPickers();
                                            togglePenMode();
                                          },
                                          width: optionWidth,
                                          height: optionHeight,
                                        ),
                                        SizedBox(height: optionGap),
                                        Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            SizedBox(
                                              width: optionWidth,
                                              height: optionHeight,
                                              child: Stack(
                                                clipBehavior: Clip.none,
                                                children: [
                                                  Positioned(
                                                    right: 0,
                                                    top: 0,
                                                    child: isThicknessPickerVisible &&
                                                            !isThicknessPickerForEraser
                                                        ? GestureDetector(
                                                            onTap: () {
                                                              final shouldClose =
                                                                  isThicknessPickerVisible &&
                                                                      !isThicknessPickerForEraser;
                                                              setThicknessPickerVisible(
                                                                  !shouldClose);
                                                            },
                                                            behavior:
                                                                HitTestBehavior
                                                                    .opaque,
                                                            child: SizedBox(
                                                              width:
                                                                  thicknessIconExpandedWidth,
                                                              height:
                                                                  optionHeight,
                                                              child: ClipRRect(
                                                                borderRadius:
                                                                    const BorderRadius
                                                                        .only(
                                                                  topRight: Radius
                                                                      .circular(
                                                                          16),
                                                                  bottomRight: Radius
                                                                      .circular(
                                                                          16),
                                                                ),
                                                                child:
                                                                    SvgPicture
                                                                        .asset(
                                                                  'assets/images/Thickness_open.svg',
                                                                  fit: BoxFit
                                                                      .fill,
                                                                ),
                                                              ),
                                                            ),
                                                          )
                                                        : _buildLayoutImageViewerToolButton(
                                                            iconAssetPath:
                                                                'assets/images/Thickness.svg',
                                                            onTap: () {
                                                              if (!isPenModeActive) {
                                                                setDialogState(
                                                                    () {
                                                                  isPenModeActive =
                                                                      true;
                                                                  isEraserModeActive =
                                                                      false;
                                                                  isPanModeActive =
                                                                      false;
                                                                });
                                                              }
                                                              final shouldClose =
                                                                  isThicknessPickerVisible &&
                                                                      !isThicknessPickerForEraser;
                                                              setThicknessPickerVisible(
                                                                  !shouldClose);
                                                            },
                                                            width: optionWidth,
                                                            height:
                                                                optionHeight,
                                                          ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        SizedBox(height: optionGap),
                                        Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            SizedBox(
                                              width: optionWidth,
                                              height: optionHeight,
                                              child: Stack(
                                                clipBehavior: Clip.none,
                                                children: [
                                                  Positioned(
                                                    right: 0,
                                                    top: 0,
                                                    child: isColorPickerVisible
                                                        ? GestureDetector(
                                                            onTap: () {
                                                              final shouldClose =
                                                                  isColorPickerVisible;
                                                              setColorPickerVisible(
                                                                  !shouldClose);
                                                            },
                                                            behavior:
                                                                HitTestBehavior
                                                                    .opaque,
                                                            child: SizedBox(
                                                              width:
                                                                  thicknessIconExpandedWidth,
                                                              height:
                                                                  optionHeight,
                                                              child: ClipRRect(
                                                                borderRadius:
                                                                    const BorderRadius
                                                                        .only(
                                                                  topRight: Radius
                                                                      .circular(
                                                                          16),
                                                                  bottomRight: Radius
                                                                      .circular(
                                                                          16),
                                                                ),
                                                                child:
                                                                    SvgPicture
                                                                        .asset(
                                                                  'assets/images/Color_open.svg',
                                                                  fit: BoxFit
                                                                      .fill,
                                                                ),
                                                              ),
                                                            ),
                                                          )
                                                        : _buildLayoutImageViewerToolButton(
                                                            iconAssetPath:
                                                                'assets/images/Color.svg',
                                                            onTap: () {
                                                              if (!isPenModeActive) {
                                                                setDialogState(
                                                                    () {
                                                                  isPenModeActive =
                                                                      true;
                                                                  isEraserModeActive =
                                                                      false;
                                                                  isPanModeActive =
                                                                      false;
                                                                });
                                                              }
                                                              final shouldClose =
                                                                  isColorPickerVisible;
                                                              setColorPickerVisible(
                                                                  !shouldClose);
                                                            },
                                                            width: optionWidth,
                                                            height:
                                                                optionHeight,
                                                          ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        SizedBox(height: optionGap),
                                        Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            SizedBox(
                                              width: optionWidth,
                                              height: optionHeight,
                                              child: Stack(
                                                clipBehavior: Clip.none,
                                                children: [
                                                  Positioned(
                                                    right: 0,
                                                    top: 0,
                                                    child: (isThicknessPickerVisible &&
                                                            isThicknessPickerForEraser)
                                                        ? GestureDetector(
                                                            onTap: () {
                                                              activateEraserMode();
                                                              final shouldClose =
                                                                  isThicknessPickerVisible &&
                                                                      isThicknessPickerForEraser;
                                                              setThicknessPickerVisible(
                                                                !shouldClose,
                                                                forEraser: true,
                                                              );
                                                            },
                                                            behavior:
                                                                HitTestBehavior
                                                                    .opaque,
                                                            child: SizedBox(
                                                              width:
                                                                  thicknessIconExpandedWidth,
                                                              height:
                                                                  optionHeight,
                                                              child: ClipRRect(
                                                                borderRadius:
                                                                    const BorderRadius
                                                                        .only(
                                                                  topRight: Radius
                                                                      .circular(
                                                                          16),
                                                                  bottomRight: Radius
                                                                      .circular(
                                                                          16),
                                                                ),
                                                                child:
                                                                    SvgPicture
                                                                        .asset(
                                                                  'assets/images/Eraser_open.svg',
                                                                  fit: BoxFit
                                                                      .fill,
                                                                ),
                                                              ),
                                                            ),
                                                          )
                                                        : _buildLayoutImageViewerToolButton(
                                                            iconAssetPath:
                                                                'assets/images/Eraser.svg',
                                                            onTap: () {
                                                              activateEraserMode();
                                                              final shouldClose =
                                                                  isThicknessPickerVisible &&
                                                                      isThicknessPickerForEraser;
                                                              setThicknessPickerVisible(
                                                                !shouldClose,
                                                                forEraser: true,
                                                              );
                                                            },
                                                            width: optionWidth,
                                                            height:
                                                                optionHeight,
                                                          ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        SizedBox(height: optionGap),
                                        _buildLayoutImageViewerToolButton(
                                          iconAssetPath:
                                              'assets/images/Zoom in.svg',
                                          onTap: () {
                                            closeToolPickers();
                                            setDialogState(() {
                                              zoomByStep(0.1);
                                            });
                                          },
                                          width: optionWidth,
                                          height: optionHeight,
                                        ),
                                        SizedBox(height: optionGap),
                                        _buildLayoutImageViewerToolButton(
                                          iconAssetPath:
                                              'assets/images/Zoom out.svg',
                                          onTap: () {
                                            closeToolPickers();
                                            setDialogState(() {
                                              zoomByStep(-0.1);
                                            });
                                          },
                                          width: optionWidth,
                                          height: optionHeight,
                                        ),
                                        SizedBox(height: optionGap),
                                        _buildLayoutImageViewerToolButton(
                                          iconAssetPath:
                                              'assets/images/recenterr.svg',
                                          onTap: () {
                                            closeToolPickers();
                                            setDialogState(() {
                                              viewerController.value =
                                                  Matrix4.identity();
                                            });
                                          },
                                          width: optionWidth,
                                          height: optionHeight,
                                        ),
                                        SizedBox(height: optionGap),
                                        _buildLayoutImageViewerToolButton(
                                          iconAssetPath: isPanModeActive
                                              ? 'assets/images/Pan_active.svg'
                                              : 'assets/images/Pan.svg',
                                          onTap: () {
                                            closeToolPickers();
                                            activatePanMode();
                                          },
                                          width: optionWidth,
                                          height: optionHeight,
                                        ),
                                        SizedBox(height: optionGap),
                                        _buildLayoutImageViewerToolButton(
                                          iconAssetPath:
                                              'assets/images/Delete_image.svg',
                                          isLoading: isDeletingImage,
                                          loadingColor: const Color(0xFFFF0000),
                                          onTap: () async {
                                            if (isDeletingImage) return;
                                            closeToolPickers();
                                            final shouldDelete =
                                                await showDeleteImageDialog();
                                            if (!shouldDelete || !mounted) {
                                              return;
                                            }
                                            try {
                                              setDialogState(
                                                () => isDeletingImage = true,
                                              );
                                              skipPersistOnClose = true;
                                              if (dialogContext.mounted) {
                                                Navigator.of(dialogContext)
                                                    .pop();
                                              }
                                              await deleteLayoutImageAndMetadata();
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'Layout image deleted.',
                                                  ),
                                                ),
                                              );
                                            } catch (e) {
                                              skipPersistOnClose = false;
                                              if (dialogContext.mounted) {
                                                setDialogState(
                                                  () => isDeletingImage = false,
                                                );
                                              }
                                              if (mounted) {
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(
                                                  SnackBar(
                                                    content: Text(
                                                      'Failed to delete layout image: $e',
                                                    ),
                                                  ),
                                                );
                                              }
                                            }
                                          },
                                          width: optionWidth,
                                          height: optionHeight,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Positioned(
                                top: toolTop(0) -
                                    closeIconGapToPen -
                                    closeIconSize,
                                right: closeIconRightInset,
                                child: _buildLayoutImageViewerToolButton(
                                  iconAssetPath:
                                      'assets/images/Layout_close.svg',
                                  onTap: () async {
                                    closeToolPickers();
                                    if (!hasPendingEdits) {
                                      if (dialogContext.mounted) {
                                        Navigator.of(dialogContext).pop();
                                      }
                                      return;
                                    }
                                    final closeDecision =
                                        await showUnsavedEditsDialog();
                                    if (closeDecision == null) return;
                                    if (closeDecision ==
                                        _LayoutViewerCloseDecision.discard) {
                                      skipPersistOnClose = true;
                                    }
                                    if (dialogContext.mounted) {
                                      Navigator.of(dialogContext).pop();
                                    }
                                  },
                                  width: closeIconSize,
                                  height: closeIconSize,
                                ),
                              ),
                              if (isThicknessPickerVisible &&
                                  !isThicknessPickerForEraser)
                                Positioned(
                                  right: thicknessIconExpandedWidth -
                                      thicknessPanelRightShift,
                                  top: toolTop(1) + thicknessPanelTopOffset,
                                  child: _buildLayoutThicknessPicker(
                                    panelWidth: thicknessPanelWidth,
                                    optionColor: Colors.black,
                                    selectedIndex: selectedThicknessIndex,
                                    onOptionTap: (index) {
                                      setDialogState(() {
                                        selectedThicknessIndex = index;
                                      });
                                    },
                                  ),
                                ),
                              if (isColorPickerVisible)
                                Positioned(
                                  right: thicknessIconExpandedWidth -
                                      thicknessPanelRightShift,
                                  top: toolTop(2) + thicknessPanelTopOffset,
                                  child: _buildLayoutColorPicker(
                                    panelWidth: thicknessPanelWidth,
                                    selectedIndex: selectedColorIndex,
                                    onOptionTap: (index) {
                                      setDialogState(() {
                                        selectedColorIndex = index;
                                      });
                                    },
                                  ),
                                ),
                              if (isThicknessPickerVisible &&
                                  isThicknessPickerForEraser)
                                Positioned(
                                  right: thicknessIconExpandedWidth -
                                      thicknessPanelRightShift,
                                  top: toolTop(3) + thicknessPanelTopOffset,
                                  child: _buildLayoutThicknessPicker(
                                    panelWidth: thicknessPanelWidth,
                                    optionColor: Colors.black.withOpacity(0.5),
                                    selectedIndex: selectedEraserThicknessIndex,
                                    onOptionTap: (index) {
                                      setDialogState(() {
                                        selectedEraserThicknessIndex = index;
                                      });
                                    },
                                  ),
                                ),
                              Positioned(
                                right: railGapFromImage + optionWidth,
                                top: closeTopInset +
                                    imageTopInset +
                                    imageBoxHeight +
                                    bottomActionTopGap,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildLayoutImageViewerToolButton(
                                      iconAssetPath:
                                          'assets/images/Download_doc.svg',
                                      onTap: () async {
                                        final preOpenedWindow =
                                            _tryPreOpenBrowserWindow();
                                        try {
                                          await persistEditsIfNeeded();
                                          final latestStoragePath = isAmenityImage
                                              ? _amenityLayoutImagePath.trim()
                                              : (layoutIndex != null &&
                                                      layoutIndex >= 0 &&
                                                      layoutIndex <
                                                          _layouts.length
                                                  ? (_layouts[layoutIndex][
                                                              'layoutImagePath'] ??
                                                          '')
                                                      .toString()
                                                  : '');
                                          final latestUrl =
                                              await _resolveDocumentPublicUrl(
                                            latestStoragePath,
                                          );
                                          final resolvedUrl = latestUrl.isEmpty
                                              ? imageUrl.trim()
                                              : latestUrl.trim();
                                          if (resolvedUrl.isEmpty) {
                                            _closeBrowserPopupWindow(
                                              preOpenedWindow,
                                            );
                                            return;
                                          }
                                          await _downloadFileForCurrentPlatform(
                                            fileUrl: resolvedUrl,
                                            fileName: _layoutImageDownloadName(
                                              isAmenityImage: isAmenityImage,
                                              layoutIndex: layoutIndex,
                                              fallbackLabel: layoutName,
                                              storagePathOrUrl:
                                                  latestStoragePath.isEmpty
                                                      ? resolvedUrl
                                                      : latestStoragePath,
                                            ),
                                            preOpenedWindow: preOpenedWindow,
                                          );
                                        } catch (e) {
                                          _closeBrowserPopupWindow(
                                            preOpenedWindow,
                                          );
                                          if (mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  'Failed to download image: $e',
                                                ),
                                              ),
                                            );
                                          }
                                        }
                                      },
                                      width: bottomActionIconWidth,
                                      height: bottomActionIconHeight,
                                    ),
                                    SizedBox(width: bottomActionIconGap),
                                    _buildLayoutImageViewerToolButton(
                                      iconAssetPath:
                                          'assets/images/Print doc.svg',
                                      onTap: () async {
                                        final preOpenedWindow =
                                            _tryPreOpenBrowserWindow();
                                        try {
                                          await persistEditsIfNeeded();
                                          final latestStoragePath = isAmenityImage
                                              ? _amenityLayoutImagePath.trim()
                                              : (layoutIndex != null &&
                                                      layoutIndex >= 0 &&
                                                      layoutIndex <
                                                          _layouts.length
                                                  ? (_layouts[layoutIndex][
                                                              'layoutImagePath'] ??
                                                          '')
                                                      .toString()
                                                  : '');
                                          final latestUrl =
                                              await _resolveDocumentPublicUrl(
                                            latestStoragePath,
                                          );
                                          final resolvedUrl = latestUrl.isEmpty
                                              ? imageUrl.trim()
                                              : latestUrl.trim();
                                          if (resolvedUrl.isEmpty) {
                                            _closeBrowserPopupWindow(
                                              preOpenedWindow,
                                            );
                                            return;
                                          }
                                          await _printImageForCurrentPlatform(
                                            imageUrl: resolvedUrl,
                                            title: _layoutImageDownloadName(
                                              isAmenityImage: isAmenityImage,
                                              layoutIndex: layoutIndex,
                                              fallbackLabel: layoutName,
                                              storagePathOrUrl:
                                                  latestStoragePath.isEmpty
                                                      ? resolvedUrl
                                                      : latestStoragePath,
                                            ),
                                            preOpenedWindow: preOpenedWindow,
                                          );
                                        } catch (e) {
                                          _closeBrowserPopupWindow(
                                            preOpenedWindow,
                                          );
                                          if (mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  'Failed to print image: $e',
                                                ),
                                              ),
                                            );
                                          }
                                        }
                                      },
                                      width: bottomActionIconWidth,
                                      height: bottomActionIconHeight,
                                    ),
                                  ],
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
            );
          },
        );
      },
    ).then((_) async {
      await persistEditsIfNeeded();
      viewerController.dispose();
    });
  }

  Widget _buildLayoutImageViewerToolButton({
    required String iconAssetPath,
    required VoidCallback onTap,
    bool isLoading = false,
    Color loadingColor = const Color(0xFF0C8CE9),
    double width = 75,
    double height = 73,
  }) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        height: height,
        child: isLoading
            ? Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: loadingColor,
                  ),
                ),
              )
            : SvgPicture.asset(
                iconAssetPath,
                fit: BoxFit.fill,
              ),
      ),
    );
  }

  static const List<double> _layoutThicknessOptions = [1, 3, 5, 7];
  static const List<Color> _layoutColorOptions = [
    Color(0xFF06AB00),
    Color(0xFFFF0000),
    Color(0xFF0C8CE9),
    Color(0xFFFFB12A),
  ];

  Widget _buildLayoutThicknessPicker({
    required double panelWidth,
    required Color optionColor,
    required int selectedIndex,
    required ValueChanged<int> onOptionTap,
  }) {
    const rowHeight = 24.0;
    const rowGap = 16.0;
    const lineLength = 50.0;

    return Container(
      width: panelWidth,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 4,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(_layoutThicknessOptions.length, (index) {
          final isSelected = index == selectedIndex;
          final strokeHeight = _layoutThicknessOptions[index];

          return Padding(
            padding: EdgeInsets.only(
              bottom: index == _layoutThicknessOptions.length - 1 ? 0 : rowGap,
            ),
            child: GestureDetector(
              onTapDown: (_) => onOptionTap(index),
              onTap: () => onOptionTap(index),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: double.infinity,
                height: rowHeight,
                color:
                    isSelected ? const Color(0xFFDDDEDE) : Colors.transparent,
                alignment: Alignment.center,
                child: Container(
                  width: lineLength,
                  height: strokeHeight,
                  decoration: BoxDecoration(
                    color: optionColor,
                    borderRadius: BorderRadius.circular(strokeHeight / 2),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildLayoutColorPicker({
    required double panelWidth,
    required int selectedIndex,
    required ValueChanged<int> onOptionTap,
  }) {
    const rowHeight = 24.0;
    const rowGap = 16.0;
    const circleSize = 16.0;

    return Container(
      width: panelWidth,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 4,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(_layoutColorOptions.length, (index) {
          final isSelected = index == selectedIndex;
          final color = _layoutColorOptions[index];

          return Padding(
            padding: EdgeInsets.only(
              bottom: index == _layoutColorOptions.length - 1 ? 0 : rowGap,
            ),
            child: GestureDetector(
              onTapDown: (_) => onOptionTap(index),
              onTap: () => onOptionTap(index),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: double.infinity,
                height: rowHeight,
                color:
                    isSelected ? const Color(0xFFDDDEDE) : Colors.transparent,
                alignment: Alignment.center,
                child: Container(
                  width: circleSize,
                  height: circleSize,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  List<Map<String, dynamic>> _convertAmenityAreasData(
    List<Map<String, dynamic>> sourceAmenityAreas,
  ) {
    return sourceAmenityAreas.map((row) {
      final areaSqft = _parseMoneyLikeValue(row['area']);
      final statusRaw = (row['status'] ?? 'available').toString();
      final salePriceRaw =
          (row['sale_price'] ?? row['salePrice'] ?? '').toString().trim();
      final saleValueRaw =
          (row['sale_value'] ?? row['saleValue'] ?? '').toString().trim();
      final allInCostRaw =
          (row['all_in_cost'] ?? row['allInCost'] ?? '').toString().trim();
      final paymentText = (row['payment'] ?? '').toString().trim();
      final parsedPayment = _parseAmenityPaymentStorageValue(paymentText);
      final explicitPaymentAmount = _parseMoneyLikeValue(
        row['payment_amount'] ?? row['paymentAmount'],
      );
      final resolvedPaymentAmount = explicitPaymentAmount > 0
          ? explicitPaymentAmount
          : ((parsedPayment['amount'] as double?) ?? 0.0);
      return <String, dynamic>{
        'id': (row['id'] ?? '').toString(),
        'name': (row['name'] ?? '').toString().trim(),
        // Store in sqft, convert to display only while rendering.
        'area': _formatWithFixedDecimals(areaSqft, 3),
        'status': _parsePlotStatus(statusRaw),
        'allInCost': allInCostRaw,
        'salePrice': salePriceRaw,
        'saleValue': saleValueRaw,
        'buyerName':
            (row['buyer_name'] ?? row['buyerName'] ?? '').toString().trim(),
        'buyerContactNumber': (row['buyer_contact_number'] ??
                row['buyer_mobile_number'] ??
                row['buyerContactNumber'] ??
                '')
            .toString()
            .trim(),
        'payment': paymentText,
        'paymentAmount': resolvedPaymentAmount > 0
            ? _formatWithFixedDecimals(resolvedPaymentAmount, 2)
            : '',
        'agent': (row['agent_name'] ?? row['agentName'] ?? row['agent'] ?? '')
            .toString()
            .trim(),
        'saleDate':
            _formatDateFromDatabase(row['sale_date'] ?? row['saleDate']),
      };
    }).toList();
  }

  List<Map<String, dynamic>> _toDynamicMapList(dynamic raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
    final rows = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      rows.add(
        item.map(
          (key, value) => MapEntry(key.toString(), value),
        ),
      );
    }
    return rows;
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
      final plots = _coerceMapList(layout['plots']);
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

  double _resolveLivePaymentAmountForEditDialog({
    required int layoutIndex,
    required int plotIndex,
    required int paymentIndex,
    required Map<String, dynamic> payment,
  }) {
    final controlKey = '${layoutIndex}_${plotIndex}_$paymentIndex';
    final controller = _paymentAmountControllers[controlKey];
    if (controller != null) {
      return _parseMoneyLikeValue(controller.text);
    }
    return _parseMoneyLikeValue(payment['paymentAmount']);
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
    if (!widget.isActive) return;
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
      final plots = _coerceMapList(layout['plots']);
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
      final m = _coerceMap(p);
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
        final plots = _coerceMapList(layout['plots']);
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
                        color: Color(0x33000000),
                        blurRadius: 1,
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

    final List<BoxShadow> optionShadow = (isSelected && isAll)
        ? const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 2,
              offset: Offset(0, 0),
            ),
          ]
        : isSelected
            ? [
                const BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 2,
                  offset: Offset(0, 0),
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

  Widget _buildHeaderRefreshButton(VoidCallback onTap) {
    return HeaderRefreshButton(onTap: onTap);
  }

  Widget _buildLayoutsHeadingRow({bool useFilterButtonKey = true}) {
    final hasLayoutsForActiveTab =
        _activeContentTab == PlotStatusContentTab.site
            ? _layouts.isNotEmpty
            : _hasAmenityAreaData;

    return Stack(
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
            Opacity(
              opacity: hasLayoutsForActiveTab ? 1.0 : 0.5,
              child: IgnorePointer(
                ignoring: !hasLayoutsForActiveTab,
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        print('Filter button tapped, showing dropdown');
                        _showFilterDropdown(context);
                      },
                      child: Container(
                        key: useFilterButtonKey ? _filterButtonKey : null,
                        height: 36,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.white,
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
                            SvgPicture.asset(
                              'assets/images/Filter.svg',
                              width: 16,
                              height: 10,
                              fit: BoxFit.contain,
                              placeholderBuilder: (context) => const SizedBox(
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
                      onTap: () => _handleLayoutControlTap(
                        'plot_expand_all',
                        () {
                          setState(() {
                            if (_activeContentTab ==
                                PlotStatusContentTab.amenityArea) {
                              _isAmenityAreaCollapsed = false;
                            } else {
                              _collapsedLayouts.clear();
                            }
                          });
                        },
                      ),
                      child: Container(
                        height: 36,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: _layoutControlBackground('plot_expand_all'),
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
                              'Expand all layouts',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w400,
                                color: Colors.black,
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
                                  placeholderBuilder: (context) =>
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
                    GestureDetector(
                      onTap: () => _handleLayoutControlTap(
                        'plot_collapse_all',
                        () {
                          setState(() {
                            if (_activeContentTab ==
                                PlotStatusContentTab.amenityArea) {
                              _isAmenityAreaCollapsed = true;
                            } else {
                              _collapsedLayouts.clear();
                              for (int i = 0; i < _layouts.length; i++) {
                                _collapsedLayouts.add(i);
                              }
                            }
                          });
                        },
                      ),
                      child: Container(
                        height: 36,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: _layoutControlBackground('plot_collapse_all'),
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
                              'Collapse all layouts',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w400,
                                color: Colors.black,
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
                                  placeholderBuilder: (context) =>
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
                    Text(
                      'Zoom',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTapDown: (_) =>
                          _setLayoutZoomPressed('plot_zoom_out', true),
                      onTapUp: (_) =>
                          _setLayoutZoomPressed('plot_zoom_out', false),
                      onTapCancel: () =>
                          _setLayoutZoomPressed('plot_zoom_out', false),
                      onTap: () => _handleLayoutControlTap(
                        'plot_zoom_out',
                        () {
                          setState(() {
                            _tableZoomLevel = _stepTableZoomLevel(
                              _tableZoomLevel,
                              increase: false,
                            );
                          });
                        },
                      ),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color:
                              _layoutPressedZoomKeys.contains('plot_zoom_out')
                                  ? const Color(0xFFEDEDED)
                                  : Colors.white,
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
                        child: SvgPicture.asset(
                          'assets/images/Zoom_out.svg',
                          width: 36,
                          height: 36,
                          fit: BoxFit.contain,
                          placeholderBuilder: (context) => const SizedBox(
                            width: 36,
                            height: 36,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
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
                    GestureDetector(
                      onTapDown: (_) =>
                          _setLayoutZoomPressed('plot_zoom_in', true),
                      onTapUp: (_) =>
                          _setLayoutZoomPressed('plot_zoom_in', false),
                      onTapCancel: () =>
                          _setLayoutZoomPressed('plot_zoom_in', false),
                      onTap: () => _handleLayoutControlTap(
                        'plot_zoom_in',
                        () {
                          setState(() {
                            _tableZoomLevel = _stepTableZoomLevel(
                              _tableZoomLevel,
                              increase: true,
                            );
                          });
                        },
                      ),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _layoutPressedZoomKeys.contains('plot_zoom_in')
                              ? const Color(0xFFEDEDED)
                              : Colors.white,
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
                        child: SvgPicture.asset(
                          'assets/images/Zoom_in.svg',
                          width: 36,
                          height: 36,
                          fit: BoxFit.contain,
                          placeholderBuilder: (context) => const SizedBox(
                            width: 36,
                            height: 36,
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
      ],
    );
  }

  @override
  @override
  Widget build(BuildContext context) {
    if (widget.isActive) {
      print(
          '🔨 BUILD: Widget rebuilding. _allPlots count: ${_allPlots.length}');
    }
    final screenWidth = MediaQuery.of(context).size.width;
    final scaleMetrics = AppScaleMetrics.of(context);
    final extraTabLineWidth = scaleMetrics?.rightOverflowWidth ?? 0.0;
    final isMobile = screenWidth < 768;
    final isTablet = screenWidth >= 768 && screenWidth < 1024;
    _scheduleLayoutsStickyStateUpdate();

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
                        Row(
                          mainAxisSize: MainAxisSize.min,
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
                            const SizedBox(width: 12),
                            _buildHeaderRefreshButton(() {
                              unawaited(
                                _loadPlotDataAndNotify(
                                  showLoadingIndicator: true,
                                  forceRefresh: true,
                                  forceFullPageSkeleton: true,
                                ),
                              );
                            }),
                          ],
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
                          _setActiveContentTab(PlotStatusContentTab.site);
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
                            _setActiveContentTab(
                              PlotStatusContentTab.amenityArea,
                            );
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewportWidth =
                      constraints.maxWidth + extraTabLineWidth;
                  final viewportHeight = constraints.maxHeight;
                  return OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: viewportWidth,
                    maxWidth: viewportWidth,
                    minHeight: viewportHeight,
                    maxHeight: viewportHeight,
                    child: SizedBox(
                      width: viewportWidth,
                      height: viewportHeight,
                      child: Stack(
                        key: _contentViewportKey,
                        fit: StackFit.expand,
                        children: [
                          ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context)
                                .copyWith(scrollbars: false),
                            child: ScrollbarTheme(
                              data: ScrollbarThemeData(
                                crossAxisMargin: 8,
                                mainAxisMargin: 8,
                                thickness: MaterialStateProperty.all(8),
                                thumbColor: MaterialStateProperty.resolveWith(
                                  (states) {
                                    if (states
                                            .contains(MaterialState.hovered) ||
                                        states
                                            .contains(MaterialState.dragged)) {
                                      return _scrollbarThumbActiveColor;
                                    }
                                    return _scrollbarThumbBaseColor;
                                  },
                                ),
                                thumbVisibility:
                                    MaterialStateProperty.all(true),
                                radius: const Radius.circular(4),
                                minThumbLength: 233,
                              ),
                              child: Scrollbar(
                                controller: _scrollController,
                                thumbVisibility: true,
                                trackVisibility: false,
                                interactive: true,
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _buildTopOverallSalesAndSiteStatusCards(),
                                      const SizedBox(height: 24),
                                      // Layouts heading with expand/collapse/zoom controls
                                      KeyedSubtree(
                                        key: _layoutsToolbarAnchorKey,
                                        child: _showStickyLayoutsToolbar
                                            ? const SizedBox(
                                                height:
                                                    _layoutsToolbarAnchorHeight,
                                              )
                                            : _buildLayoutsHeadingRow(
                                                useFilterButtonKey: true,
                                              ),
                                      ),
                                      const SizedBox(height: 24),
                                      if (_activeContentTab ==
                                          PlotStatusContentTab.site) ...[
                                        if (_isLoading &&
                                            (_forceShowFullPageLoadingSkeleton ||
                                                _layouts.isEmpty))
                                          _buildLayoutsLoadingSkeleton()
                                        else if (_layouts.isEmpty)
                                          SizedBox(
                                            width: double.infinity,
                                            height: math.max(
                                              320,
                                              viewportHeight - 272,
                                            ),
                                            child: Container(
                                              width: double.infinity,
                                              padding: const EdgeInsets.all(16),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFF8F9FA),
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
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      'No Layouts Added',
                                                      textAlign:
                                                          TextAlign.center,
                                                      style: GoogleFonts.inter(
                                                        fontSize: 24,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                        color: Colors.black,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 16),
                                                    Text(
                                                      'Add layouts and plots in Site tab to view theri status here',
                                                      textAlign:
                                                          TextAlign.center,
                                                      style: GoogleFonts.inter(
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.w400,
                                                        color: Colors.black
                                                            .withOpacity(0.8),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 16),
                                                    InkWell(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              8),
                                                      onTap: widget
                                                          .onNavigateToDataEntrySite,
                                                      child: Container(
                                                        width: 149,
                                                        height: 36,
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                                horizontal: 16,
                                                                vertical: 4),
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
                                                                      0.25),
                                                              blurRadius: 2,
                                                              offset:
                                                                  const Offset(
                                                                      0, 0),
                                                            ),
                                                          ],
                                                        ),
                                                        alignment:
                                                            Alignment.center,
                                                        child: FittedBox(
                                                          fit: BoxFit.scaleDown,
                                                          child: Text(
                                                            'Data Entry \u2192 Site',
                                                            maxLines: 1,
                                                            softWrap: false,
                                                            style: GoogleFonts
                                                                .inter(
                                                              fontSize: 14,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w400,
                                                              color: const Color(
                                                                  0xFF0C8CE9),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          )
                                        else
                                          ...List.generate(_layouts.length,
                                              (layoutIndex) {
                                            return Container(
                                              margin: const EdgeInsets.only(
                                                  bottom: 24),
                                              child: _buildLayoutCard(
                                                  layoutIndex,
                                                  _layouts[layoutIndex]),
                                            );
                                          }),
                                      ] else ...[
                                        if (!_hasAmenityAreaData)
                                          Center(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Icon(
                                                  Icons.inbox_outlined,
                                                  size: 64,
                                                  color: Colors.black
                                                      .withOpacity(0.3),
                                                ),
                                                const SizedBox(height: 16),
                                                Text(
                                                  'No amenity area found',
                                                  style: GoogleFonts.inter(
                                                    fontSize: 16,
                                                    fontWeight:
                                                        FontWeight.normal,
                                                    color: Colors.black
                                                        .withOpacity(0.5),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          )
                                        else
                                          Container(
                                            margin: const EdgeInsets.only(
                                                bottom: 24),
                                            child: _buildAmenityAreaCard(),
                                          ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (_showStickyLayoutsToolbar)
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.only(
                                  left: 24,
                                  right: 24,
                                  top: 8,
                                  bottom: 8,
                                ),
                                color: Colors.white,
                                child: _buildLayoutsHeadingRow(
                                  useFilterButtonKey: true,
                                ),
                              ),
                            ),
                          if (_isLoading && _forceShowFullPageLoadingSkeleton)
                            Positioned.fill(
                              child: IgnorePointer(
                                ignoring: true,
                                child: _buildPlotStatusPageLoadingOverlay(),
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
                          unawaited(_discardCurrentEditDialogChanges());
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
    final focusNode = _saleDateFocusNodes[key]!;
    final isEmpty = controller.text.trim().isEmpty;

    Future<void> openSaleDatePicker() async {
      FocusManager.instance.primaryFocus?.unfocus();
      final initialDate = _parseDate(controller.text.trim()) ?? DateTime.now();
      final DateTime? picked =
          await _showStyledPlotStatusDatePicker(initialDate: initialDate);
      if (picked != null) {
        final formattedDate =
            '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
        controller.value = TextEditingValue(
          text: formattedDate,
          selection: TextSelection.collapsed(offset: formattedDate.length),
        );
        _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
            ['saleDate'] = formattedDate;
        setState(() {
          _syncEditingPlotToAllPlots();
        });
      }
      FocusManager.instance.primaryFocus?.unfocus();
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: openSaleDatePicker,
      child: Container(
        height: 40,
        width: 133,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: focusNode.hasFocus
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
              child: Text(
                isEmpty ? 'dd/mm/yyyy' : controller.text.trim(),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: isEmpty ? const Color(0xFFC1C1C1) : Colors.black,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
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
      final normalizedSalePrice = salePrice
          .replaceAll(',', '')
          .replaceAll('₹', '')
          .replaceAll(' ', '')
          .trim();
      final seedText = normalizedSalePrice.isEmpty ||
              normalizedSalePrice == '0' ||
              normalizedSalePrice == '0.00'
          ? ''
          : salePrice;
      _salePriceControllers[key] = TextEditingController(text: seedText);
      _salePriceFocusNodes[key] = _createDialogFocusNode();
    }
    final controller = _salePriceControllers[key]!;
    final salePriceFocusNode = _salePriceFocusNodes[key]!;
    final cleaned = controller.text
        .replaceAll(',', '')
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .trim();
    final isEmpty = cleaned.isEmpty || cleaned == '0' || cleaned == '0.00';

    void commitSalePriceFormatting() {
      final rawValue = controller.text
          .replaceAll(',', '')
          .replaceAll('₹', '')
          .replaceAll(' ', '')
          .trim();
      final rawNumber = double.tryParse(rawValue) ?? 0.0;
      if (rawValue.isEmpty || rawNumber <= 0) {
        controller.value = const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
          composing: TextRange.empty,
        );
        setState(() {
          _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
              ['salePrice'] = '0.00';
          _syncEditingPlotToAllPlots();
        });
        _saveLayoutsData();
        return;
      }
      final formatted = _formatAmount(rawValue);
      controller.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
        composing: TextRange.empty,
      );
      setState(() {
        _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
            ['salePrice'] = formatted;
        _syncEditingPlotToAllPlots();
      });
      _saveLayoutsData();
    }

    void focusSalePriceWithoutSelecting() {
      if (!salePriceFocusNode.hasFocus) {
        salePriceFocusNode.requestFocus();
      }
      final offset = controller.text.length;
      controller.selection = TextSelection.collapsed(offset: offset);
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: focusSalePriceWithoutSelecting,
      child: Container(
        height: 40,
        width: 209,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: salePriceFocusNode.hasFocus
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
                focusNode: salePriceFocusNode,
                selectAllOnFocus: false,
                keyboardType: TextInputType.number,
                inputFormatters: [IndianNumberFormatter()],
                textInputAction: TextInputAction.done,
                cursorColor: Colors.black,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: isEmpty
                      ? const Color(0xFFADADAD).withOpacity(0.75)
                      : Colors.black,
                ),
                decoration: InputDecoration(
                  hintText: '0.00',
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
                onEditingComplete: () {
                  commitSalePriceFormatting();
                  FocusScope.of(context).unfocus();
                },
                onSubmitted: (_) {
                  commitSalePriceFormatting();
                  FocusScope.of(context).unfocus();
                },
                onTapOutside: (_) {
                  commitSalePriceFormatting();
                  FocusScope.of(context).unfocus();
                },
              ),
            ),
          ],
        ),
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
                  ? '0.00'
                  : _formatAmount(saleValue.toStringAsFixed(2)),
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
        key: ValueKey('buyer_name_${key}_${_buyerNameFieldEpoch[key] ?? 0}'),
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
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
        onChanged: (value) {
          setState(() {
            _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
                ['buyerName'] = value;
            _syncEditingPlotToAllPlots();
          });
          _saveLayoutsData();
        },
        onEditingComplete: () {
          FocusScope.of(context).unfocus();
          setState(() {
            _resetBuyerNameFieldToStart(key);
          });
        },
        onSubmitted: (_) {
          FocusScope.of(context).unfocus();
          setState(() {
            _resetBuyerNameFieldToStart(key);
          });
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
                : Colors.black.withOpacity(0.25),
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
                color: Colors.black,
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
        plot['payments'] = <Map<String, dynamic>>[];
      }
    }

    final payments = _ensureEditablePaymentsList(plot);

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
          final payment = entry.value;
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
    final payments = _ensureEditablePaymentsList(plot);
    final canRemovePayment = payments.length > 1;

    return Container(
      width: 341,
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
    final payments = _ensureEditablePaymentsList(plot);
    if (paymentIndex >= payments.length) {
      payments.add({
        'paymentMethod': '',
        'paymentAmount': '0',
      });
    }
    final payment = payments[paymentIndex];
    final plotKey = '${_editingLayoutIndex}_${_editingPlotIndex}_$paymentIndex';

    final amount = payment['paymentAmount'] as String? ?? '0';
    final cleanedAmount = amount
        .toString()
        .replaceAll(',', '')
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .trim();
    final amountNum = double.tryParse(cleanedAmount) ?? 0.0;
    final desiredAmountText =
        amountNum == 0.0 ? '' : _formatAmount(cleanedAmount);
    final amountController = _paymentAmountControllers.putIfAbsent(
      plotKey,
      () => TextEditingController(text: desiredAmountText),
    );
    final amountFocusNode =
        _paymentAmountFocusNodes.putIfAbsent(plotKey, _createDialogFocusNode);
    if (!amountFocusNode.hasFocus &&
        amountController.text != desiredAmountText) {
      amountController.value = TextEditingValue(
        text: desiredAmountText,
        selection: TextSelection.collapsed(offset: desiredAmountText.length),
        composing: TextRange.empty,
      );
    }

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
                      controller: amountController,
                      focusNode: amountFocusNode,
                      hintText: '0',
                      textInputAction: TextInputAction.done,
                      inputFormatters: [
                        IndianNumberFormatter(maxIntegerDigits: 11)
                      ],
                      onTap: () {
                        // Clear '0.00' when field is tapped
                        final cleaned = amountController.text
                            .replaceAll(',', '')
                            .replaceAll('₹', '')
                            .replaceAll(' ', '')
                            .trim();
                        if (cleaned == '0' || cleaned == '0.00') {
                          amountController.text = '';
                          amountController.selection =
                              TextSelection.collapsed(offset: 0);
                          setState(() {});
                        }
                      },
                      onChanged: (value) {
                        // Remove commas for storage (for real-time calculations)
                        final rawValue = value
                            .replaceAll(',', '')
                            .replaceAll('₹', '')
                            .replaceAll(' ', '')
                            .trim();
                        if (rawValue.isEmpty) {
                          // Avoid clearing stored amount from transient submit/focus
                          // events. Empty should be committed only on edit complete.
                          setState(() {});
                          return;
                        }
                        final latestPayments =
                            _ensureEditablePaymentsList(plot);
                        if (paymentIndex >= latestPayments.length) {
                          latestPayments.add(_createDefaultPaymentEntry(''));
                        }
                        final latestPayment = latestPayments[paymentIndex];
                        setState(() {
                          latestPayment['paymentAmount'] = rawValue;
                          _syncEditingPlotToAllPlots();
                        });
                        _saveLayoutsData();
                        // Trigger rebuild to update shadow color
                        setState(() {});
                      },
                      onEditingComplete: () {
                        // Preserve value on Enter even if the display controller
                        // briefly reports empty during focus transitions.
                        final entered = amountController.text
                            .replaceAll(',', '')
                            .replaceAll('₹', '')
                            .replaceAll(' ', '')
                            .trim();
                        final latestPayments =
                            _ensureEditablePaymentsList(plot);
                        if (paymentIndex >= latestPayments.length) {
                          latestPayments.add(_createDefaultPaymentEntry(''));
                        }
                        final latestPayment = latestPayments[paymentIndex];
                        final existing = (latestPayment['paymentAmount'] ?? '')
                            .toString()
                            .replaceAll(',', '')
                            .replaceAll('₹', '')
                            .replaceAll(' ', '')
                            .trim();
                        final raw = entered.isNotEmpty ? entered : existing;
                        if (raw.isEmpty) {
                          const fallback = '0.00';
                          amountController.value = TextEditingValue(
                            text: fallback,
                            selection: TextSelection.collapsed(
                                offset: fallback.length),
                          );
                          setState(() {
                            latestPayment['paymentAmount'] = fallback;
                            _syncEditingPlotToAllPlots();
                          });
                          _saveLayoutsData();
                          return;
                        }
                        final formatted = _formatAmount(raw);
                        amountController.value = TextEditingValue(
                          text: formatted,
                          selection:
                              TextSelection.collapsed(offset: formatted.length),
                        );
                        setState(() {
                          latestPayment['paymentAmount'] =
                              formatted.replaceAll(',', '');
                          _syncEditingPlotToAllPlots();
                        });
                        _saveLayoutsData();
                        _collapsePaymentAmountSelectionForPlot(
                          _editingLayoutIndex!,
                          _editingPlotIndex!,
                        );
                        FocusScope.of(context).unfocus();
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

  Future<DateTime?> _showStyledPlotStatusDatePicker({
    required DateTime initialDate,
  }) async {
    return showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      barrierColor: Colors.black.withValues(alpha: 0.64),
      builder: (context, child) {
        final theme = Theme.of(context);
        const pickerBlue = Color(0xFF0C8CE9);
        final pickerBlueTint =
            Color.alphaBlend(pickerBlue.withValues(alpha: 0.12), Colors.white);
        return Theme(
          data: theme.copyWith(
            colorScheme: theme.colorScheme.copyWith(
              primary: pickerBlue,
              secondary: pickerBlue,
              onPrimary: Colors.white,
              surface: pickerBlueTint,
              surfaceTint: pickerBlueTint,
            ),
            datePickerTheme: DatePickerThemeData(
              backgroundColor: pickerBlueTint,
              surfaceTintColor: pickerBlueTint,
              headerBackgroundColor: pickerBlue,
              headerForegroundColor: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
  }

  Widget _buildDateField(String label, String fieldKey, String placeholder,
      [int paymentIndex = 0]) {
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;
    final payments = _ensureEditablePaymentsList(plot);
    if (paymentIndex >= payments.length) {
      payments.add({
        'paymentMethod': '',
        'paymentAmount': '0',
      });
    }
    final payment = payments[paymentIndex];
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
            FocusScope.of(context).unfocus();
            final layoutIndex = _editingLayoutIndex!;
            final plotIndex = _editingPlotIndex!;
            final plotKey = '${layoutIndex}_${plotIndex}_$paymentIndex';
            _collapsePaymentAmountSelectionForPlot(layoutIndex, plotIndex);
            final DateTime? picked = await _showStyledPlotStatusDatePicker(
              initialDate: dateValue.isNotEmpty
                  ? _parseDate(dateValue) ?? DateTime.now()
                  : DateTime.now(),
            );
            if (picked != null) {
              final formattedDate =
                  '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
              setState(() {
                payment[fieldKey] = formattedDate;
                _syncEditingPlotToAllPlots();
              });
              final amountController = _paymentAmountControllers[plotKey];
              if (amountController != null) {
                final text = amountController.text;
                amountController.value = amountController.value.copyWith(
                  text: text,
                  selection: TextSelection.collapsed(offset: text.length),
                  composing: TextRange.empty,
                );
              }
              _collapsePaymentAmountSelectionForPlot(layoutIndex, plotIndex);
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
    final payments = _ensureEditablePaymentsList(plot);
    if (paymentIndex >= payments.length) {
      payments.add({
        'paymentMethod': '',
        'paymentAmount': '0',
      });
    }
    final payment = payments[paymentIndex];
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
    final payments = _ensureEditablePaymentsList(plot);
    if (paymentIndex >= payments.length) {
      payments.add({
        'paymentMethod': '',
        'paymentAmount': '0',
      });
    }
    final payment = payments[paymentIndex];
    final currentPaymentMethod = payment['paymentMethod'] as String? ?? '';
    final isLongBankTransferMethod =
        currentPaymentMethod == 'Bank Transfer (NEFT / RTGS / IMPS)';
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
                                        padding: EdgeInsets.only(
                                          right:
                                              isLongBankTransferMethod ? 8 : 16,
                                        ),
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
                                          fontSize: isLongBankTransferMethod
                                              ? 13
                                              : 14,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.black,
                                        ),
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.ellipsis,
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
                      final payments = _ensureEditablePaymentsList(plot);
                      if (_currentPaymentIndex >= payments.length) {
                        payments.add({
                          'paymentMethod': methodName,
                          'paymentAmount': '0',
                        });
                      } else {
                        payments[_currentPaymentIndex]['paymentMethod'] =
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
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
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

    if (_editingLayoutIndex! < 0 || _editingLayoutIndex! >= _layouts.length) {
      _scheduleInvalidEditDialogReset();
      return const SizedBox.shrink();
    }

    final layout = _layouts[_editingLayoutIndex!];
    final plotsRaw = layout['plots'] as List<dynamic>? ?? const [];
    if (_editingPlotIndex! < 0 || _editingPlotIndex! >= plotsRaw.length) {
      _scheduleInvalidEditDialogReset();
      return const SizedBox.shrink();
    }
    final plotRaw = plotsRaw[_editingPlotIndex!];
    if (plotRaw is! Map<String, dynamic>) {
      _scheduleInvalidEditDialogReset();
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
                        onTap: () async {
                          await _discardCurrentEditDialogChanges();
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
                            _rebuildAllPlotsFromLayouts(
                                reason: 'edit_dialog_update');
                            _closeCurrentEditDialog();
                          });
                          // Save all changes in background after closing dialog.
                          await _saveLayoutsData(immediate: true);
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
                                                      _rebuildAllPlotsFromLayouts(
                                                          reason:
                                                              'edit_dialog_status_change');
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
                                      'Buyer Contact Number (Optional)',
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
                                        final payments =
                                            _ensureEditablePaymentsList(plot);
                                        final layoutIndex =
                                            _editingLayoutIndex!;
                                        final plotIndex = _editingPlotIndex!;
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
                                        for (final entry
                                            in payments.asMap().entries) {
                                          totalAmount +=
                                              _resolveLivePaymentAmountForEditDialog(
                                            layoutIndex: layoutIndex,
                                            plotIndex: plotIndex,
                                            paymentIndex: entry.key,
                                            payment: entry.value,
                                          );
                                        }

                                        final remainingAmount =
                                            saleValue - totalAmount;
                                        const epsilon = 0.01;
                                        final totalExceeds =
                                            totalAmount > saleValue + epsilon;
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
                                        final totalColor = remainingIsZero
                                            ? const Color(0xFF1A8F3E)
                                            : Colors.red;

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
                                        final payments =
                                            _ensureEditablePaymentsList(plot);
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
                                        _clearPaymentInputCachesForPlot(
                                          _editingLayoutIndex!,
                                          _editingPlotIndex!,
                                        );
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
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE3E7EB), width: 1),
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

  Widget _buildPlotStatusPageLoadingOverlay() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.only(
        top: 28,
        left: 24,
        right: 24,
        bottom: 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
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
                  _skeletonBlock(width: 120, height: 14),
                  const SizedBox(height: 12),
                  _skeletonBlock(width: double.infinity, height: 24),
                  const SizedBox(height: 12),
                  _skeletonBlock(width: double.infinity, height: 24),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _buildLayoutsLoadingSkeleton(),
          ],
        ),
      ),
    );
  }

  Widget _buildPlotStatusTable() {
    final filteredPlots = _filteredPlots;

    if (_isLoading &&
        (_forceShowFullPageLoadingSkeleton || filteredPlots.isEmpty)) {
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

    return ScrollbarTheme(
      data: ScrollbarThemeData(
        crossAxisMargin: 0,
        mainAxisMargin: 0,
        thumbColor: MaterialStateProperty.resolveWith(
          (states) {
            if (states.contains(MaterialState.hovered) ||
                states.contains(MaterialState.dragged)) {
              return _scrollbarThumbActiveColor;
            }
            return _scrollbarThumbBaseColor;
          },
        ),
      ),
      child: Scrollbar(
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
                  final layout =
                      filteredPlots[index]['layout'] as String? ?? '';
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
                  final area =
                      filteredPlots[index]['area'] as String? ?? '0.00';
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
                  final status =
                      _parsePlotStatus(filteredPlots[index]['status']);
                  final statusColor = _getStatusColor(status);
                  final statusText = _getStatusString(status);
                  final statusBackgroundColor =
                      _getStatusBackgroundColor(status);
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
          final paidAmount = _resolveAmenityPaidAmount(areaData);

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
      const double targetOverviewWidth = 904;

      final overviewCard = Container(
        width: targetOverviewWidth,
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
      );

      return LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : targetOverviewWidth;

          if (availableWidth >= targetOverviewWidth) {
            return SizedBox(
              width: targetOverviewWidth,
              child: overviewCard,
            );
          }

          return SizedBox(
            width: availableWidth,
            child: FittedBox(
              fit: BoxFit.fitWidth,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: targetOverviewWidth,
                child: overviewCard,
              ),
            ),
          );
        },
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

  Widget _buildLayoutImageUploadControl({
    required bool hasUploadedLayoutImage,
    required bool isUploading,
    required VoidCallback onOpenUploadedImage,
    required VoidCallback onUploadNewImage,
  }) {
    final layoutImageIconAsset = hasUploadedLayoutImage
        ? 'assets/images/Expense_doc_after_upload.svg'
        : 'assets/images/Expense_doc.svg';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (isUploading) return;
        if (hasUploadedLayoutImage) {
          onOpenUploadedImage();
        } else {
          onUploadNewImage();
        }
      },
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
        child: isUploading
            ? const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Color(0xFF0C8CE9)),
                  ),
                ),
              )
            : SvgPicture.asset(
                layoutImageIconAsset,
                width: 36,
                height: 36,
                fit: BoxFit.contain,
              ),
      ),
    );
  }

  Widget _buildLayoutCard(int layoutIndex, Map<String, dynamic> layout) {
    final plots = _coerceMapList(layout['plots']);
    final layoutName = layout['name'] as String? ?? 'Layout ${layoutIndex + 1}';
    final layoutImagePath = (layout['layoutImagePath'] ?? '').toString().trim();
    final layoutImageDocId =
        (layout['layoutImageDocId'] ?? '').toString().trim();
    final hasUploadedLayoutImage =
        layoutImagePath.isNotEmpty || layoutImageDocId.isNotEmpty;
    final isUploadingLayoutImage =
        _layoutImageUploadInProgress.contains(layoutIndex);

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
              const SizedBox(width: 24),
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 24),
              Text(
                'Layout Image: ',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              _buildLayoutImageUploadControl(
                hasUploadedLayoutImage: hasUploadedLayoutImage,
                isUploading: isUploadingLayoutImage,
                onOpenUploadedImage: () {
                  unawaited(_openLayoutDocumentForLayout(layoutIndex));
                },
                onUploadNewImage: () {
                  unawaited(_uploadLayoutDocumentForLayout(layoutIndex));
                },
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
                  child: ScrollbarTheme(
                    data: ScrollbarThemeData(
                      crossAxisMargin: 0,
                      mainAxisMargin: 0,
                      thumbColor: MaterialStateProperty.resolveWith(
                        (states) {
                          if (states.contains(MaterialState.hovered) ||
                              states.contains(MaterialState.dragged)) {
                            return _scrollbarThumbActiveColor;
                          }
                          return _scrollbarThumbBaseColor;
                        },
                      ),
                    ),
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
                            left: ((_tableZoomLevel - 1.0) * 10.0)
                                .clamp(0.0, 10.0),
                            right: ((_tableZoomLevel - 1.0) * 10.0)
                                .clamp(0.0, 10.0),
                            top: ((_tableZoomLevel - 1.0) * 10.0)
                                .clamp(0.0, 10.0),
                            bottom: ((_tableZoomLevel - 1.0) * 10.0)
                                    .clamp(0.0, 10.0) +
                                ((_tableZoomLevel - 1.0) * 100.0).clamp(0.0,
                                    100.0), // Extra bottom padding for scaled borders to prevent clipping
                          ),
                          child: Align(
                            alignment: Alignment.topLeft,
                            widthFactor: _tableZoomLevel,
                            heightFactor: _tableZoomLevel,
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
    final hasUploadedAmenityLayoutImage =
        _amenityLayoutImagePath.trim().isNotEmpty ||
            _amenityLayoutImageDocId.trim().isNotEmpty;
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
              const SizedBox(width: 16),
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 16),
              Text(
                'Layout Image: ',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 8),
              _buildLayoutImageUploadControl(
                hasUploadedLayoutImage: hasUploadedAmenityLayoutImage,
                isUploading: _isAmenityLayoutImageUploadInProgress,
                onOpenUploadedImage: () {
                  unawaited(_openLayoutDocumentForAmenity());
                },
                onUploadNewImage: () {
                  unawaited(_uploadLayoutDocumentForAmenity());
                },
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
                    child: ScrollbarTheme(
                      data: ScrollbarThemeData(
                        crossAxisMargin: 0,
                        mainAxisMargin: 0,
                        thumbColor: MaterialStateProperty.resolveWith(
                          (states) {
                            if (states.contains(MaterialState.hovered) ||
                                states.contains(MaterialState.dragged)) {
                              return _scrollbarThumbActiveColor;
                            }
                            return _scrollbarThumbBaseColor;
                          },
                        ),
                      ),
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
                                  .clamp(0.0, 10.0),
                              top: ((_tableZoomLevel - 1.0) * 10.0)
                                  .clamp(0.0, 10.0),
                              bottom: ((_tableZoomLevel - 1.0) * 10.0)
                                      .clamp(0.0, 10.0) +
                                  ((_tableZoomLevel - 1.0) * 100.0)
                                      .clamp(0.0, 100.0),
                            ),
                            child: Align(
                              alignment: Alignment.topLeft,
                              widthFactor: _tableZoomLevel,
                              heightFactor: _tableZoomLevel,
                              child: Transform.scale(
                                scale: _tableZoomLevel,
                                alignment: Alignment.topLeft,
                                child: SizedBox(
                                  height: baseHeight,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child:
                                        _buildAmenityAreaTable(filteredAreas),
                                  ),
                                ),
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
          header: 'All-in Cost (₹/$_areaUnitSuffix)',
          width: 215,
          plots: areas,
          builder: (area, index) {
            final allInCostSqft = _parseMoneyLikeValue(
              area['allInCost'] ?? area['all_in_cost'],
            );
            if (allInCostSqft <= 0) {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              );
            }
            final allInCostDisplay =
                AreaUnitUtils.rateFromSqftToDisplay(allInCostSqft, _isSqm);
            return Text(
              '₹ ${_formatAmount(allInCostDisplay.toStringAsFixed(2))}',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            );
          },
        ),
        _buildTableColumn(
          header: 'Plot Cost (₹)',
          width: 215,
          plots: areas,
          builder: (area, index) {
            final areaSqft = _parseMoneyLikeValue(area['area']);
            final allInCostSqft = _parseMoneyLikeValue(
              area['allInCost'] ?? area['all_in_cost'],
            );
            final plotCost = areaSqft * allInCostSqft;
            if (plotCost <= 0) {
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
              '₹ ${_formatAmount(plotCost.toStringAsFixed(2))}',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            );
          },
        ),
        _buildTableColumn(
          header: 'Sale Price (₹/$_areaUnitSuffix) *',
          width: 209,
          plots: areas,
          builder: (area, index) {
            final status = _parsePlotStatus(area['status']);
            if (!_isSoldLikeStatus(status)) {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              );
            }
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
            final status = _parsePlotStatus(area['status']);
            if (!_isSoldLikeStatus(status)) {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              );
            }
            final saleValue = _parseMoneyLikeValue(area['saleValue']);
            if (saleValue <= 0) {
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
              '₹ ${_formatAmount(saleValue.toStringAsFixed(2))}',
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
            final status = _parsePlotStatus(area['status']);
            if (!_isSoldLikeStatus(status)) {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              );
            }
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
            final status = _parsePlotStatus(area['status']);
            if (!_isSoldLikeStatus(status)) {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              );
            }
            final paymentRaw = (area['payment'] ?? '').toString().trim();
            final paymentMethods =
                (_parseAmenityPaymentStorageValue(paymentRaw)['methods'] ?? '')
                    .toString()
                    .trim();
            return Text(
              paymentMethods.isEmpty ? '-' : paymentMethods,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: paymentMethods.isEmpty
                    ? const Color(0xFF5C5C5C)
                    : Colors.black,
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
            final status = _parsePlotStatus(area['status']);
            if (!_isSoldLikeStatus(status)) {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              );
            }
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
            final status = _parsePlotStatus(area['status']);
            if (!_isSoldLikeStatus(status)) {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              );
            }
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
                        final m = _coerceMap(p);
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
                      color: salePriceEmpty ? Colors.red : Colors.transparent,
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
        // Received Amount (₹) column
        _buildTableColumn(
          header: 'Received Amount (₹)',
          width: 215,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            if (_isSoldLikeStatus(status)) {
              final receivedAmount = _calculateTotalPaidAmount(plot);
              final formattedValue =
                  _formatAmount(receivedAmount.toStringAsFixed(2));
              return SizedBox(
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
        // Pending Amount (₹) column
        _buildTableColumn(
          header: 'Pending Amount (₹)',
          width: 215,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            if (_isSoldLikeStatus(status)) {
              final salePriceStr = plot['salePrice'] as String? ?? '0.00';
              final areaStr = plot['area'] as String? ?? '0.00';
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
              final receivedAmount = _calculateTotalPaidAmount(plot);
              final pendingAmount = math.max(0.0, saleValue - receivedAmount);
              final formattedValue =
                  _formatAmount(pendingAmount.toStringAsFixed(2));
              return SizedBox(
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
                      color: buyerNameEmpty ? Colors.red : Colors.transparent,
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
          header: 'Buyer Contact Number (Optional)',
          width: 280,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            if (_isSoldLikeStatus(status)) {
              final rawBuyerContact =
                  (plot['buyerContactNumber'] as String? ?? '').trim();
              final normalizedBuyerContact =
                  rawBuyerContact.replaceFirst(RegExp(r'^\+91\s*'), '');
              if (normalizedBuyerContact.isEmpty) {
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
                '+91 $normalizedBuyerContact',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
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
                      color: isEmpty ? Colors.red : Colors.transparent,
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
                      color: agentEmpty ? Colors.red : Colors.transparent,
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
                                  : Colors.transparent,
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
    final DateTime? picked = await _showStyledPlotStatusDatePicker(
      initialDate: DateTime.now(),
    );

    if (picked != null) {
      final formattedDate =
          '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
      setState(() {
        _layouts[layoutIndex]['plots'][plotIndex]['saleDate'] = formattedDate;
        final saleDateController = _saleDateControllers[key];
        if (saleDateController != null) {
          saleDateController.value = TextEditingValue(
            text: formattedDate,
            selection: TextSelection.collapsed(offset: formattedDate.length),
          );
        }
      });
      _saleDateFocusNodes[key]?.unfocus();
      _saveLayoutsData();
    }
  }
}

class _LayoutViewerStroke {
  final List<Offset> normalizedPoints;
  final Color color;
  final double thickness;

  _LayoutViewerStroke({
    required this.normalizedPoints,
    required this.color,
    required this.thickness,
  });
}

class _LayoutViewerStrokesPainter extends CustomPainter {
  final List<_LayoutViewerStroke> strokes;
  final Size imageNaturalSize;

  const _LayoutViewerStrokesPainter({
    required this.strokes,
    this.imageNaturalSize = Size.zero,
    Listenable? repaint,
  }) : super(repaint: repaint);

  Rect _containedImageRect(Size canvasSize) {
    if (canvasSize.width <= 0 || canvasSize.height <= 0) {
      return Rect.zero;
    }
    if (imageNaturalSize.width <= 0 || imageNaturalSize.height <= 0) {
      return Offset.zero & canvasSize;
    }

    final imageAspect = imageNaturalSize.width / imageNaturalSize.height;
    final canvasAspect = canvasSize.width / canvasSize.height;
    if (imageAspect > canvasAspect) {
      final width = canvasSize.width;
      final height = width / imageAspect;
      final top = (canvasSize.height - height) / 2;
      return Rect.fromLTWH(0, top, width, height);
    }
    final height = canvasSize.height;
    final width = height * imageAspect;
    final left = (canvasSize.width - width) / 2;
    return Rect.fromLTWH(left, 0, width, height);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final imageRect = _containedImageRect(size);
    if (imageRect.width <= 0 || imageRect.height <= 0) return;

    for (final stroke in strokes) {
      if (stroke.normalizedPoints.isEmpty) continue;

      final strokeWidth =
          stroke.thickness * 2 < 1.0 ? 1.0 : stroke.thickness * 2;
      final strokePaint = Paint()
        ..color = stroke.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      Offset denormalize(Offset point) => Offset(
            imageRect.left + (point.dx * imageRect.width),
            imageRect.top + (point.dy * imageRect.height),
          );

      if (stroke.normalizedPoints.length == 1) {
        final center = denormalize(stroke.normalizedPoints.first);
        final dotPaint = Paint()
          ..color = stroke.color
          ..style = PaintingStyle.fill;
        canvas.drawCircle(center, strokePaint.strokeWidth / 2, dotPaint);
        continue;
      }

      final path = Path()
        ..moveTo(
          imageRect.left + (stroke.normalizedPoints.first.dx * imageRect.width),
          imageRect.top + (stroke.normalizedPoints.first.dy * imageRect.height),
        );
      for (int i = 1; i < stroke.normalizedPoints.length; i++) {
        final point = denormalize(stroke.normalizedPoints[i]);
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _LayoutViewerStrokesPainter oldDelegate) {
    return true;
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
