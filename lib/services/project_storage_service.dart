import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'offline_project_sync_service.dart';
import '../utils/area_unit_utils.dart';

class _ProjectDataCacheEntry {
  _ProjectDataCacheEntry(this.data, this.cachedAt);

  final Map<String, dynamic> data;
  final DateTime cachedAt;
}

class ProjectSaveQueuedForSyncException implements Exception {
  ProjectSaveQueuedForSyncException({
    required this.projectId,
    required this.reason,
  });

  final String projectId;
  final String reason;

  @override
  String toString() =>
      'Project save queued for sync (projectId=$projectId): $reason';
}

class _PendingProjectSaveOperation {
  _PendingProjectSaveOperation({
    required this.projectId,
    required this.payload,
    required this.queuedAtMs,
    this.attempts = 0,
    this.lastError = '',
  });

  final String projectId;
  final Map<String, dynamic> payload;
  final int queuedAtMs;
  int attempts;
  String lastError;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'projectId': projectId,
        'payload': payload,
        'queuedAtMs': queuedAtMs,
        'attempts': attempts,
        'lastError': lastError,
      };

  static _PendingProjectSaveOperation? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final projectId = (raw['projectId'] ?? '').toString().trim();
    if (projectId.isEmpty) return null;
    final payloadRaw = raw['payload'];
    if (payloadRaw is! Map) return null;
    final payload = <String, dynamic>{};
    payloadRaw.forEach((key, value) {
      payload[key.toString()] = value;
    });
    return _PendingProjectSaveOperation(
      projectId: projectId,
      payload: payload,
      queuedAtMs: (raw['queuedAtMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      attempts: (raw['attempts'] as num?)?.toInt() ?? 0,
      lastError: (raw['lastError'] ?? '').toString(),
    );
  }
}

class ProjectStorageService {
  static final SupabaseClient _supabase = Supabase.instance.client;
  static const String _layoutDocumentsFolderName = 'Layouts';
  static final Map<String, _ProjectDataCacheEntry> _projectDataCache = {};
  static const Duration _defaultProjectDataCacheMaxAge = Duration(seconds: 45);
  static const bool _enableVerboseLogs = false;
  static const String _pendingSaveQueuePrefsKey =
      'project_storage_pending_save_queue_v1';
  static const Duration _pendingSaveRetryInterval = Duration(seconds: 8);
  static final List<_PendingProjectSaveOperation> _pendingSaveQueue = [];
  static bool _pendingSaveQueueLoaded = false;
  static bool _isFlushingPendingSaveQueue = false;
  static Timer? _pendingSaveRetryTimer;
  static String? _plotsBuyerContactColumnName;
  static bool _plotsBuyerContactColumnChecked = false;
  static bool? _hasBuyerMobileNumberColumn;
  static String? _expenseDateColumnName;
  static bool _expenseDateColumnChecked = false;
  static String? _expenseDocColumnName;
  static bool _expenseDocColumnChecked = false;
  static String? _expenseDocPathColumnName;
  static bool _expenseDocPathColumnChecked = false;
  static String? _expenseDocIdColumnName;
  static bool _expenseDocIdColumnChecked = false;
  static String? _expenseDocExtensionColumnName;
  static bool _expenseDocExtensionColumnChecked = false;

  static void _log(Object? message) {
    if (_enableVerboseLogs) {
      dev.log(message?.toString() ?? '');
    }
  }

  static bool _isLikelyNetworkError(Object error) {
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

  static bool _isProjectRowMissingForSync(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('project_row_missing_for_sync') ||
        (msg.contains('foreign key constraint') &&
            (msg.contains('project_id') || msg.contains('layout_id'))) ||
        msg.contains('violates foreign key constraint');
  }

  static dynamic _normalizeForJson(dynamic value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is List) {
      return value.map<dynamic>(_normalizeForJson).toList(growable: false);
    }
    if (value is Map) {
      final out = <String, dynamic>{};
      value.forEach((key, val) {
        out[key.toString()] = _normalizeForJson(val);
      });
      return out;
    }
    return value.toString();
  }

  static Map<String, dynamic> _buildSavePayload({
    String? projectName,
    String? projectStatus,
    String? projectAreaUnit,
    String? projectAddress,
    String? googleMapsLink,
    String? totalArea,
    String? sellingArea,
    String? estimatedDevelopmentCost,
    List<Map<String, String>>? nonSellableAreas,
    List<Map<String, String>>? amenityAreas,
    List<Map<String, dynamic>>? partners,
    List<Map<String, dynamic>>? expenses,
    List<Map<String, dynamic>>? layouts,
    required bool partialLayoutsSync,
    List<Map<String, dynamic>>? projectManagers,
    List<Map<String, dynamic>>? agents,
  }) {
    final payload = <String, dynamic>{};
    if (projectName != null) payload['projectName'] = projectName;
    if (projectStatus != null) payload['projectStatus'] = projectStatus;
    if (projectAreaUnit != null) payload['projectAreaUnit'] = projectAreaUnit;
    if (projectAddress != null) payload['projectAddress'] = projectAddress;
    if (googleMapsLink != null) payload['googleMapsLink'] = googleMapsLink;
    if (totalArea != null) payload['totalArea'] = totalArea;
    if (sellingArea != null) payload['sellingArea'] = sellingArea;
    if (estimatedDevelopmentCost != null) {
      payload['estimatedDevelopmentCost'] = estimatedDevelopmentCost;
    }
    if (nonSellableAreas != null) {
      payload['nonSellableAreas'] = nonSellableAreas;
    }
    if (amenityAreas != null) payload['amenityAreas'] = amenityAreas;
    if (partners != null) payload['partners'] = partners;
    if (expenses != null) payload['expenses'] = expenses;
    if (layouts != null) payload['layouts'] = layouts;
    if (partialLayoutsSync) payload['partialLayoutsSync'] = true;
    if (projectManagers != null) payload['projectManagers'] = projectManagers;
    if (agents != null) payload['agents'] = agents;
    return (_normalizeForJson(payload) as Map).cast<String, dynamic>();
  }

  static List<Map<String, dynamic>>? _asMapList(dynamic raw) {
    if (raw == null) return null;
    if (raw is! List) return null;
    return raw
        .map<Map<String, dynamic>>((item) => Map<String, dynamic>.from(
            item is Map ? item : const <String, dynamic>{}))
        .toList(growable: false);
  }

  static List<Map<String, String>>? _asStringMapList(dynamic raw) {
    if (raw == null) return null;
    if (raw is! List) return null;
    return raw.map<Map<String, String>>((item) {
      final source = item is Map ? item : const <String, dynamic>{};
      final out = <String, String>{};
      source.forEach((key, value) {
        out[key.toString()] = (value ?? '').toString();
      });
      return out;
    }).toList(growable: false);
  }

  static Future<void> _ensurePendingSaveQueueLoaded() async {
    if (_pendingSaveQueueLoaded) return;
    _pendingSaveQueueLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingSaveQueuePrefsKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _pendingSaveQueue
        ..clear()
        ..addAll(decoded
            .map<_PendingProjectSaveOperation?>(
                _PendingProjectSaveOperation.fromJson)
            .whereType<_PendingProjectSaveOperation>());
    } catch (e) {
      _pendingSaveQueue.clear();
      _log('Failed to load pending save queue: $e');
    }
  }

  static Future<void> _persistPendingSaveQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_pendingSaveQueue.isEmpty) {
        await prefs.remove(_pendingSaveQueuePrefsKey);
        return;
      }
      final encoded = jsonEncode(
        _pendingSaveQueue.map((op) => op.toJson()).toList(growable: false),
      );
      await prefs.setString(_pendingSaveQueuePrefsKey, encoded);
    } catch (e) {
      _log('Failed to persist pending save queue: $e');
    }
  }

  static Future<void> _enqueuePendingSave({
    required String projectId,
    required Map<String, dynamic> payload,
    required String error,
  }) async {
    await _ensurePendingSaveQueueLoaded();
    final existingIndex =
        _pendingSaveQueue.indexWhere((entry) => entry.projectId == projectId);
    if (existingIndex >= 0) {
      final existing = _pendingSaveQueue[existingIndex];
      final mergedPayload = _mergePendingSavePayload(
        base: existing.payload,
        update: payload,
      );
      _pendingSaveQueue[existingIndex] = _PendingProjectSaveOperation(
        projectId: projectId,
        payload: mergedPayload,
        queuedAtMs: existing.queuedAtMs,
        attempts: existing.attempts,
        lastError: error,
      );
    } else {
      _pendingSaveQueue.add(
        _PendingProjectSaveOperation(
          projectId: projectId,
          payload: payload,
          queuedAtMs: DateTime.now().millisecondsSinceEpoch,
          attempts: 0,
          lastError: error,
        ),
      );
    }
    await _persistPendingSaveQueue();
    _ensurePendingSaveSyncLoop();
  }

  static Map<String, dynamic> _mergePendingSavePayload({
    required Map<String, dynamic> base,
    required Map<String, dynamic> update,
  }) {
    final merged = _deepCopyMap(base);
    for (final entry in update.entries) {
      merged[entry.key] = _deepCopyDynamic(entry.value);
    }
    return merged;
  }

  static void _ensurePendingSaveSyncLoop() {
    if (_pendingSaveRetryTimer != null) return;
    _pendingSaveRetryTimer = Timer.periodic(_pendingSaveRetryInterval, (_) {
      unawaited(flushPendingSaves());
    });
    unawaited(flushPendingSaves());
  }

  static Future<void> flushPendingSaves({String? projectId}) async {
    final normalizedProjectId = (projectId ?? '').trim();
    await _ensurePendingSaveQueueLoaded();
    if (_pendingSaveQueue.isEmpty) return;
    if (_isFlushingPendingSaveQueue) return;

    final userId = await _resolveCurrentOrLastKnownUserId();
    if (userId == null || userId.trim().isEmpty) return;
    await OfflineProjectSyncService.flushPendingCreates(
      supabase: _supabase,
      userId: userId,
    );

    _isFlushingPendingSaveQueue = true;
    try {
      var index = 0;
      while (index < _pendingSaveQueue.length) {
        final op = _pendingSaveQueue[index];
        if (normalizedProjectId.isNotEmpty &&
            op.projectId != normalizedProjectId) {
          index++;
          continue;
        }
        try {
          await saveProjectData(
            projectId: op.projectId,
            projectName: op.payload['projectName']?.toString(),
            projectStatus: op.payload['projectStatus']?.toString(),
            projectAreaUnit: op.payload['projectAreaUnit']?.toString(),
            projectAddress: op.payload['projectAddress']?.toString(),
            googleMapsLink: op.payload['googleMapsLink']?.toString(),
            totalArea: op.payload['totalArea']?.toString(),
            sellingArea: op.payload['sellingArea']?.toString(),
            estimatedDevelopmentCost:
                op.payload['estimatedDevelopmentCost']?.toString(),
            nonSellableAreas: _asStringMapList(op.payload['nonSellableAreas']),
            amenityAreas: _asStringMapList(op.payload['amenityAreas']),
            partners: _asMapList(op.payload['partners']),
            expenses: _asMapList(op.payload['expenses']),
            layouts: _asMapList(op.payload['layouts']),
            partialLayoutsSync: op.payload['partialLayoutsSync'] == true,
            projectManagers: _asMapList(op.payload['projectManagers']),
            agents: _asMapList(op.payload['agents']),
            allowOfflineQueue: false,
          );
          await _markRemoteSaveTimestampForProject(op.projectId);
          _pendingSaveQueue.removeAt(index);
          await _persistPendingSaveQueue();
          continue;
        } catch (e) {
          if (_isProjectRowMissingForSync(e)) {
            await OfflineProjectSyncService.flushPendingCreates(
              supabase: _supabase,
              userId: userId,
            );
            index++;
            continue;
          }
          op.attempts += 1;
          op.lastError = e.toString();
          await _persistPendingSaveQueue();
          if (_isLikelyNetworkError(e)) {
            break;
          }
          // Keep other pending items unblocked by stale non-network failures.
          if (op.attempts >= 3) {
            _pendingSaveQueue.removeAt(index);
            await _persistPendingSaveQueue();
            continue;
          }
          index++;
        }
      }
    } finally {
      _isFlushingPendingSaveQueue = false;
    }
  }

  static Future<bool> hasPendingOfflineSaves({String? projectId}) async {
    await _ensurePendingSaveQueueLoaded();
    final normalizedProjectId = (projectId ?? '').trim();
    if (normalizedProjectId.isEmpty) return _pendingSaveQueue.isNotEmpty;
    return _pendingSaveQueue
        .any((entry) => entry.projectId == normalizedProjectId);
  }

  static Future<void> removePendingOfflineSavesForProject(
    String projectId,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    await _ensurePendingSaveQueueLoaded();
    _pendingSaveQueue
        .removeWhere((entry) => entry.projectId == normalizedProjectId);
    await _persistPendingSaveQueue();
  }

  static Future<void> initializeOfflineSync() async {
    await _ensurePendingSaveQueueLoaded();
    _ensurePendingSaveSyncLoop();
    unawaited(flushPendingSaves());
  }

  static Future<String?> _resolveCurrentOrLastKnownUserId() async {
    return OfflineProjectSyncService.resolveCurrentOrLastKnownUserId(
      supabase: _supabase,
    );
  }

  static double _parseNumericValue(dynamic value) {
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

  static int _parseIntegerValue(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString().trim()) ?? 0;
  }

  static String _normalizePlotStatusForView(dynamic statusValue) {
    final dbValue = _normalizePlotStatusForDatabase(statusValue);
    if (dbValue == 'reserved') return 'pending';
    return dbValue;
  }

  static List<Map<String, dynamic>> _normalizeLayoutsForOverlay(dynamic raw) {
    final source = _asMapList(raw) ?? const <Map<String, dynamic>>[];
    final normalized = <Map<String, dynamic>>[];
    for (final row in source) {
      final layoutId = (row['id'] ?? '').toString().trim();
      final layoutName = (row['name'] ?? '').toString();
      final plotRows =
          _asMapList(row['plots']) ?? const <Map<String, dynamic>>[];
      final normalizedPlots = <Map<String, dynamic>>[];
      for (final plot in plotRows) {
        final area = _parseNumericValue(plot['area']);
        final allInCostPerSqft = _parseNumericValue(
          plot['all_in_cost_per_sqft'] ??
              plot['purchase_rate'] ??
              plot['purchaseRate'],
        );
        final salePrice = _parseNumericValue(
          plot['sale_price'] ?? plot['salePrice'],
        );
        normalizedPlots.add(<String, dynamic>{
          'id': (plot['id'] ?? '').toString().trim(),
          'layout_id': layoutId,
          'plot_number':
              (plot['plot_number'] ?? plot['plotNumber'] ?? '').toString(),
          'area': area,
          'all_in_cost_per_sqft': allInCostPerSqft,
          'total_plot_cost': area * allInCostPerSqft,
          'status': _normalizePlotStatusForView(plot['status']),
          'sale_price': salePrice,
          'buyer_name':
              (plot['buyer_name'] ?? plot['buyerName'] ?? '').toString(),
          'buyer_contact_number': (plot['buyer_contact_number'] ??
                  plot['buyer_mobile_number'] ??
                  plot['buyerContactNumber'] ??
                  '')
              .toString(),
          'sale_date':
              (plot['sale_date'] ?? plot['saleDate'] ?? '').toString().trim(),
          'agent_name':
              (plot['agent_name'] ?? plot['agent'] ?? '').toString().trim(),
          'payments': plot['payments'] ?? <dynamic>[],
          'partners': List<String>.from(
            ((plot['partners'] as List?) ?? const [])
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty),
          ),
        });
      }
      normalized.add(<String, dynamic>{
        ...row,
        'id': layoutId,
        'name': layoutName,
        'layout_image_name':
            (row['layout_image_name'] ?? row['layoutImageName'] ?? '')
                .toString()
                .trim(),
        'layout_image_path':
            (row['layout_image_path'] ?? row['layoutImagePath'] ?? '')
                .toString()
                .trim(),
        'layout_image_doc_id':
            (row['layout_image_doc_id'] ?? row['layoutImageDocId'] ?? '')
                .toString()
                .trim(),
        'layout_image_extension':
            (row['layout_image_extension'] ?? row['layoutImageExtension'] ?? '')
                .toString()
                .trim(),
        'plots': normalizedPlots,
      });
    }
    return normalized;
  }

  static List<Map<String, dynamic>> _flattenPlotsFromLayouts(
    List<Map<String, dynamic>> layouts,
  ) {
    final plots = <Map<String, dynamic>>[];
    for (final layout in layouts) {
      final layoutId = (layout['id'] ?? '').toString().trim();
      final layoutPlots =
          _asMapList(layout['plots']) ?? const <Map<String, dynamic>>[];
      for (final plot in layoutPlots) {
        final out = Map<String, dynamic>.from(plot);
        if ((out['layout_id'] ?? '').toString().trim().isEmpty &&
            layoutId.isNotEmpty) {
          out['layout_id'] = layoutId;
        }
        plots.add(out);
      }
    }
    return plots;
  }

  static List<Map<String, dynamic>> _normalizeCompensationRows(dynamic raw) {
    final source = _asMapList(raw) ?? const <Map<String, dynamic>>[];
    return source.map((row) {
      return <String, dynamic>{
        'id': (row['id'] ?? '').toString().trim(),
        'name': (row['name'] ?? '').toString(),
        'compensation_type':
            (row['compensation_type'] ?? row['compensation'] ?? '').toString(),
        'earning_type':
            (row['earning_type'] ?? row['earningType'] ?? '').toString(),
        'percentage': _parseNumericValue(row['percentage']),
        'fixed_fee': _parseNumericValue(row['fixed_fee'] ?? row['fixedFee']),
        'monthly_fee':
            _parseNumericValue(row['monthly_fee'] ?? row['monthlyFee']),
        'months': _parseIntegerValue(row['months']),
        'per_sqft_fee':
            _parseNumericValue(row['per_sqft_fee'] ?? row['perSqftFee']),
        'fee': _parseNumericValue(row['fee']),
        'selectedBlocks': row['selectedBlocks'] ?? const <dynamic>[],
      };
    }).toList(growable: false);
  }

  static double _sumCompensationRows(
    List<Map<String, dynamic>> rows, {
    required double totalSalesValue,
    required double grossProfit,
    required double sellingArea,
  }) {
    var total = 0.0;
    for (final row in rows) {
      final explicitFee = _parseNumericValue(row['fee']);
      if (explicitFee > 0) {
        total += explicitFee;
        continue;
      }

      final fixedFee = _parseNumericValue(row['fixed_fee'] ?? row['fixedFee']);
      final monthlyFee =
          _parseNumericValue(row['monthly_fee'] ?? row['monthlyFee']);
      final months = _parseIntegerValue(row['months']);
      final percentage = _parseNumericValue(row['percentage']);
      final perSqftFee =
          _parseNumericValue(row['per_sqft_fee'] ?? row['perSqftFee']);
      final earningType =
          (row['earning_type'] ?? row['earningType'] ?? '').toString().trim();

      if (fixedFee > 0) {
        total += fixedFee;
        continue;
      }
      if (monthlyFee > 0 && months > 0) {
        total += (monthlyFee * months);
        continue;
      }
      if (perSqftFee > 0 && sellingArea > 0) {
        total += perSqftFee * sellingArea;
        continue;
      }
      if (percentage > 0) {
        final lower = earningType.toLowerCase();
        if (lower.contains('selling')) {
          total += (totalSalesValue * percentage) / 100;
        } else if (lower.contains('profit')) {
          total += (grossProfit * percentage) / 100;
        }
      }
    }
    return total;
  }

  static Future<Map<String, dynamic>?> _pendingSavePayloadForProject(
    String projectId,
  ) async {
    await _ensurePendingSaveQueueLoaded();
    for (final entry in _pendingSaveQueue.reversed) {
      if (entry.projectId != projectId) continue;
      return _deepCopyMap(entry.payload);
    }
    return null;
  }

  static void _recomputeDerivedProjectSummaryValues(Map<String, dynamic> data) {
    final totalArea =
        _parseNumericValue(data['totalArea'] ?? data['total_area']);
    final sellingArea =
        _parseNumericValue(data['sellingArea'] ?? data['selling_area']);
    final estimatedCost = _parseNumericValue(
      data['estimatedDevelopmentCost'] ?? data['estimated_development_cost'],
    );

    final nonSellableAreas =
        _asMapList(data['nonSellableAreas']) ?? const <Map<String, dynamic>>[];
    final amenityAreas =
        _asMapList(data['amenityAreas']) ?? const <Map<String, dynamic>>[];
    final expenses =
        _asMapList(data['expenses']) ?? const <Map<String, dynamic>>[];
    final layouts =
        _asMapList(data['layouts']) ?? const <Map<String, dynamic>>[];
    var plots = _asMapList(data['plots']) ?? const <Map<String, dynamic>>[];
    if (plots.isEmpty && layouts.isNotEmpty) {
      plots = _flattenPlotsFromLayouts(layouts);
      data['plots'] = plots;
    }

    final totalNonSellable = nonSellableAreas.fold<double>(
      0.0,
      (sum, row) => sum + _parseNumericValue(row['area']),
    );
    final totalExpenses = expenses.fold<double>(
      0.0,
      (sum, row) => sum + _parseNumericValue(row['amount']),
    );
    final totalLayouts = layouts.length;
    final totalPlots = plots.length;
    final soldPlots = plots
        .where((plot) => _normalizePlotStatusForView(plot['status']) == 'sold')
        .length;
    final availablePlots = plots
        .where((plot) =>
            _normalizePlotStatusForView(plot['status']) == 'available')
        .length;

    final totalPlotArea = plots.fold<double>(
      0.0,
      (sum, row) => sum + _parseNumericValue(row['area']),
    );
    final allInCostTotal = plots.fold<double>(
      0.0,
      (sum, row) =>
          sum +
          (_parseNumericValue(row['area']) *
              _parseNumericValue(row['all_in_cost_per_sqft'])),
    );
    final allInCost = totalPlotArea > 0 ? allInCostTotal / totalPlotArea : 0.0;

    final soldPlotsRows = plots
        .where((plot) => _normalizePlotStatusForView(plot['status']) == 'sold')
        .toList(growable: false);
    final totalSalesValue = soldPlotsRows.fold<double>(
      0.0,
      (sum, row) =>
          sum +
          (_parseNumericValue(row['sale_price']) *
              _parseNumericValue(row['area'])),
    );
    final avgSalePrice = soldPlotsRows.isEmpty
        ? 0.0
        : soldPlotsRows.fold<double>(
              0.0,
              (sum, row) => sum + _parseNumericValue(row['sale_price']),
            ) /
            soldPlotsRows.length;

    final projectManagers =
        _asMapList(data['project_managers']) ?? const <Map<String, dynamic>>[];
    final agents = _asMapList(data['agents']) ?? const <Map<String, dynamic>>[];
    final grossProfit = totalSalesValue - allInCostTotal;
    final totalPmCompensation = _sumCompensationRows(
      projectManagers,
      totalSalesValue: totalSalesValue,
      grossProfit: grossProfit,
      sellingArea: sellingArea,
    );
    final totalAgentCompensation = _sumCompensationRows(
      agents,
      totalSalesValue: totalSalesValue,
      grossProfit: grossProfit,
      sellingArea: sellingArea,
    );
    final totalCompensation = totalPmCompensation + totalAgentCompensation;
    final netProfit = grossProfit - totalCompensation;
    final profitMargin =
        totalSalesValue > 0 ? (netProfit / totalSalesValue) * 100 : 0.0;
    final roi = estimatedCost > 0 ? (netProfit / estimatedCost) * 100 : 0.0;

    data['totalArea'] = totalArea.toStringAsFixed(2);
    data['sellingArea'] = sellingArea.toStringAsFixed(2);
    data['estimatedDevelopmentCost'] = estimatedCost.toStringAsFixed(2);
    data['nonSellableArea'] = totalNonSellable.toStringAsFixed(2);
    data['allInCost'] = allInCost.toStringAsFixed(2);
    data['totalExpenses'] = totalExpenses.toStringAsFixed(2);
    data['totalLayouts'] = totalLayouts;
    data['totalPlots'] = totalPlots;
    data['soldPlots'] = soldPlots;
    data['availablePlots'] = availablePlots;
    data['totalSalesValue'] = totalSalesValue.toStringAsFixed(2);
    data['avgSalesPrice'] = avgSalePrice.toStringAsFixed(2);
    data['grossProfit'] = grossProfit.toStringAsFixed(2);
    data['netProfit'] = netProfit.toStringAsFixed(2);
    data['profitMargin'] = profitMargin.toStringAsFixed(2);
    data['roi'] = roi.toStringAsFixed(2);
    data['totalPMCompensation'] = totalPmCompensation.toStringAsFixed(2);
    data['totalAgentCompensation'] = totalAgentCompensation.toStringAsFixed(2);
    data['totalCompensation'] = totalCompensation.toStringAsFixed(2);
    data['amenityAreaRowCount'] = amenityAreas.length;
  }

  static Map<String, dynamic> _overlayPendingPayloadOnProjectData({
    required Map<String, dynamic> baseData,
    required Map<String, dynamic> payload,
  }) {
    final merged = _deepCopyMap(baseData);
    void setIfPresent(String payloadKey, String targetKey) {
      if (!payload.containsKey(payloadKey)) return;
      merged[targetKey] = payload[payloadKey];
    }

    setIfPresent('projectName', 'projectName');
    setIfPresent('projectStatus', 'projectStatus');
    if (payload.containsKey('projectAreaUnit')) {
      merged['projectAreaUnit'] = AreaUnitUtils.canonicalizeAreaUnit(
        payload['projectAreaUnit']?.toString(),
      );
    }
    setIfPresent('projectAddress', 'projectAddress');
    setIfPresent('googleMapsLink', 'googleMapsLink');
    setIfPresent('totalArea', 'totalArea');
    setIfPresent('sellingArea', 'sellingArea');
    setIfPresent('estimatedDevelopmentCost', 'estimatedDevelopmentCost');

    if (payload.containsKey('nonSellableAreas')) {
      merged['nonSellableAreas'] =
          _asMapList(payload['nonSellableAreas']) ?? <Map<String, dynamic>>[];
    }
    if (payload.containsKey('amenityAreas')) {
      final rows =
          _asMapList(payload['amenityAreas']) ?? <Map<String, dynamic>>[];
      merged['amenityAreas'] = rows.map((row) {
        return <String, dynamic>{
          ...row,
          'area': _parseNumericValue(row['area']),
          'all_in_cost':
              _parseNumericValue(row['all_in_cost'] ?? row['allInCost']),
        };
      }).toList(growable: false);
    }
    if (payload.containsKey('partners')) {
      merged['partners'] =
          _asMapList(payload['partners']) ?? <Map<String, dynamic>>[];
    }
    if (payload.containsKey('expenses')) {
      merged['expenses'] =
          _asMapList(payload['expenses']) ?? <Map<String, dynamic>>[];
    }
    if (payload.containsKey('layouts')) {
      final layouts = _normalizeLayoutsForOverlay(payload['layouts']);
      merged['layouts'] = layouts;
      merged['plots'] = _flattenPlotsFromLayouts(layouts);
      final plotPartners = <Map<String, dynamic>>[];
      for (final plot
          in _asMapList(merged['plots']) ?? const <Map<String, dynamic>>[]) {
        final plotId = (plot['id'] ?? '').toString().trim();
        if (plotId.isEmpty) continue;
        final partners = ((plot['partners'] as List?) ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty);
        for (final partnerName in partners) {
          plotPartners.add(<String, dynamic>{
            'plot_id': plotId,
            'partner_name': partnerName,
          });
        }
      }
      merged['plot_partners'] = plotPartners;
    }
    if (payload.containsKey('projectManagers')) {
      merged['project_managers'] =
          _normalizeCompensationRows(payload['projectManagers']);
    }
    if (payload.containsKey('agents')) {
      merged['agents'] = _normalizeCompensationRows(payload['agents']);
    }

    _recomputeDerivedProjectSummaryValues(merged);
    return merged;
  }

  static Future<void> _markRemoteSaveTimestampForProject(
    String projectId,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'project_${normalizedProjectId}_last_remote_save_ms',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // Best-effort metadata update.
    }
  }

  static Future<String?> _resolvePlotsBuyerContactColumnName() async {
    if (_plotsBuyerContactColumnChecked &&
        _plotsBuyerContactColumnName != null) {
      return _plotsBuyerContactColumnName;
    }
    _plotsBuyerContactColumnName = null;
    for (final column in const [
      'buyer_contact_number',
      'buyer_mobile_number'
    ]) {
      try {
        await _supabase.from('plots').select(column).limit(1);
        _plotsBuyerContactColumnName = column;
        break;
      } catch (_) {
        // Try next candidate.
      }
    }
    _plotsBuyerContactColumnChecked = _plotsBuyerContactColumnName != null;
    return _plotsBuyerContactColumnName;
  }

  static Future<bool> _supportsBuyerMobileNumberColumn() async {
    if (_hasBuyerMobileNumberColumn != null) {
      return _hasBuyerMobileNumberColumn!;
    }
    try {
      await _supabase.from('plots').select('buyer_mobile_number').limit(1);
      _hasBuyerMobileNumberColumn = true;
    } catch (_) {
      _hasBuyerMobileNumberColumn = false;
    }
    return _hasBuyerMobileNumberColumn!;
  }

  static Future<String?> _resolveExistingExpenseColumn(
      List<String> candidates) async {
    for (final column in candidates) {
      try {
        await _supabase.from('expenses').select(column).limit(1);
        return column;
      } catch (_) {
        // try next candidate
      }
    }
    return null;
  }

  static Future<String?> _resolveExpenseDateColumnName() async {
    if (_expenseDateColumnChecked) return _expenseDateColumnName;
    _expenseDateColumnName = await _resolveExistingExpenseColumn([
      'expense_date',
      'date',
    ]);
    _expenseDateColumnChecked = true;
    return _expenseDateColumnName;
  }

  static Future<String?> _resolveExpenseDocColumnName() async {
    if (_expenseDocColumnChecked) return _expenseDocColumnName;
    _expenseDocColumnName = await _resolveExistingExpenseColumn([
      'doc',
      'document',
      'document_no',
      'doc_no',
      'invoice_no',
      'receipt_no',
    ]);
    _expenseDocColumnChecked = true;
    return _expenseDocColumnName;
  }

  static Future<String?> _resolveExpenseDocPathColumnName() async {
    if (_expenseDocPathColumnChecked) return _expenseDocPathColumnName;
    _expenseDocPathColumnName = await _resolveExistingExpenseColumn([
      'doc_path',
      'expense_doc_path',
      'document_path',
    ]);
    _expenseDocPathColumnChecked = true;
    return _expenseDocPathColumnName;
  }

  static Future<String?> _resolveExpenseDocIdColumnName() async {
    if (_expenseDocIdColumnChecked) return _expenseDocIdColumnName;
    _expenseDocIdColumnName = await _resolveExistingExpenseColumn([
      'doc_id',
      'document_id',
      'expense_document_id',
    ]);
    _expenseDocIdColumnChecked = true;
    return _expenseDocIdColumnName;
  }

  static Future<String?> _resolveExpenseDocExtensionColumnName() async {
    if (_expenseDocExtensionColumnChecked) {
      return _expenseDocExtensionColumnName;
    }
    _expenseDocExtensionColumnName = await _resolveExistingExpenseColumn([
      'doc_extension',
      'expense_doc_extension',
      'document_extension',
    ]);
    _expenseDocExtensionColumnChecked = true;
    return _expenseDocExtensionColumnName;
  }

  static String _normalizePlotStatusForDatabase(dynamic statusValue) {
    var normalized =
        (statusValue ?? 'available').toString().trim().toLowerCase();
    // Handle enum-style strings like "PlotStatus.reserved".
    if (normalized.contains('.')) {
      normalized = normalized.split('.').last;
    }

    // DB constraint accepts "reserved" (not "pending").
    // UI uses "reserved"/"pending" interchangeably and now also has "blocked".
    // Persist all pending-like states as "reserved".
    switch (normalized) {
      case 'available':
      case 'sold':
        return normalized;
      case 'reserved':
      case 'pending':
      case 'blocked':
        return 'reserved';
      default:
        return 'available';
    }
  }

  static Future<String?> _findRootDocumentsFolderIdByName(
    String projectId,
    String folderName,
  ) async {
    final existing = (await _supabase
            .from('documents')
            .select('id,parent_id,name,created_at')
            .eq('project_id', projectId)
            .eq('type', 'folder')
            .order('created_at', ascending: true))
        .cast<Map<String, dynamic>>();

    if (existing.isEmpty) return null;
    final wanted = folderName.trim().toLowerCase();

    for (final row in existing) {
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

  static Future<void> _syncLayoutDocumentsFolderName({
    required String projectId,
    required String layoutId,
    required String layoutName,
    String previousLayoutName = '',
  }) async {
    final normalizedLayoutId = layoutId.trim();
    final normalizedLayoutName = layoutName.trim();
    if (normalizedLayoutId.isEmpty || normalizedLayoutName.isEmpty) return;

    try {
      final layoutsRootId = await _findRootDocumentsFolderIdByName(
        projectId,
        _layoutDocumentsFolderName,
      );
      if (layoutsRootId == null || layoutsRootId.isEmpty) return;

      final childFolders = (await _supabase
              .from('documents')
              .select('id,name')
              .eq('project_id', projectId)
              .eq('type', 'folder')
              .eq('parent_id', layoutsRootId)
              .order('created_at', ascending: true)
              .limit(500))
          .cast<Map<String, dynamic>>();
      if (childFolders.isEmpty) return;

      final candidateByCurrentName = childFolders.firstWhere(
        (row) =>
            (row['name'] ?? '').toString().trim().toLowerCase() ==
            normalizedLayoutName.toLowerCase(),
        orElse: () => <String, dynamic>{},
      );
      if ((candidateByCurrentName['id'] ?? '').toString().trim().isNotEmpty) {
        // Already in sync.
        return;
      }

      String candidateFolderId = '';
      final normalizedPathMarker = '/layout_$normalizedLayoutId/';
      for (final folderRow in childFolders) {
        final folderId = (folderRow['id'] ?? '').toString().trim();
        if (folderId.isEmpty) continue;

        final files = await _supabase
            .from('documents')
            .select('file_url')
            .eq('project_id', projectId)
            .eq('type', 'file')
            .eq('parent_id', folderId)
            .order('created_at', ascending: false)
            .limit(50);
        if (files.isEmpty) continue;

        var matched = false;
        for (final fileRow in files) {
          final fileUrl = (fileRow['file_url'] ?? '').toString();
          if (fileUrl.contains(normalizedPathMarker)) {
            matched = true;
            break;
          }
        }
        if (matched) {
          candidateFolderId = folderId;
          break;
        }
      }

      if (candidateFolderId.isEmpty && previousLayoutName.trim().isNotEmpty) {
        final fallbackByPreviousName = childFolders.firstWhere(
          (row) =>
              (row['name'] ?? '').toString().trim().toLowerCase() ==
              previousLayoutName.trim().toLowerCase(),
          orElse: () => <String, dynamic>{},
        );
        candidateFolderId =
            (fallbackByPreviousName['id'] ?? '').toString().trim();
      }

      if (candidateFolderId.isEmpty) return;

      await _supabase
          .from('documents')
          .update({'name': normalizedLayoutName}).eq('id', candidateFolderId);
    } catch (e) {
      _log('_syncLayoutDocumentsFolderName skipped for "$layoutName": $e');
    }
  }

  /// Fetch complete project data from Supabase by projectId
  static Future<Map<String, dynamic>?> fetchProjectDataById(
    String projectId, {
    bool forceRefresh = false,
    Duration maxAge = _defaultProjectDataCacheMaxAge,
  }) async {
    Map<String, dynamic>? pendingPayload;
    Map<String, dynamic>? queuedPayload;
    try {
      _ensurePendingSaveSyncLoop();
      unawaited(flushPendingSaves(projectId: projectId));
      pendingPayload = await _pendingSavePayloadForProject(projectId);
      queuedPayload = pendingPayload;
      if (!forceRefresh) {
        final cached = _projectDataCache[projectId];
        if (cached != null &&
            DateTime.now().difference(cached.cachedAt) <= maxAge) {
          final cachedData = _deepCopyMap(cached.data);
          if (queuedPayload != null) {
            return _overlayPendingPayloadOnProjectData(
              baseData: cachedData,
              payload: queuedPayload,
            );
          }
          return cachedData;
        }
      }

      final userId = await _resolveCurrentOrLastKnownUserId();
      if (userId == null || userId.trim().isEmpty) {
        if (queuedPayload != null) {
          final synthetic = _buildLocalPendingProjectData(<String, dynamic>{
            'project_name': queuedPayload['projectName'] ?? '',
            'project_status': queuedPayload['projectStatus'] ?? 'Active',
            'area_unit': queuedPayload['projectAreaUnit'],
            'project_address': queuedPayload['projectAddress'] ?? '',
            'google_maps_link': queuedPayload['googleMapsLink'] ?? '',
          });
          final merged = _overlayPendingPayloadOnProjectData(
            baseData: synthetic,
            payload: queuedPayload,
          );
          _projectDataCache[projectId] =
              _ProjectDataCacheEntry(_deepCopyMap(merged), DateTime.now());
          return _deepCopyMap(merged);
        }
        throw Exception('User not authenticated');
      }

      // Fetch main project info
      final project = await _supabase
          .from('projects')
          .select()
          .eq('id', projectId)
          .maybeSingle();
      if (project == null) {
        final pending =
            await OfflineProjectSyncService.getPendingProjectEntryById(
          projectId,
          userId: userId,
        );
        if (pending == null) {
          if (queuedPayload != null) {
            final synthetic = _buildLocalPendingProjectData(<String, dynamic>{
              'project_name': queuedPayload['projectName'] ?? '',
              'project_status': queuedPayload['projectStatus'] ?? 'Active',
              'area_unit': queuedPayload['projectAreaUnit'],
              'project_address': queuedPayload['projectAddress'] ?? '',
              'google_maps_link': queuedPayload['googleMapsLink'] ?? '',
            });
            final merged = _overlayPendingPayloadOnProjectData(
              baseData: synthetic,
              payload: queuedPayload,
            );
            _projectDataCache[projectId] =
                _ProjectDataCacheEntry(_deepCopyMap(merged), DateTime.now());
            return _deepCopyMap(merged);
          }
          return null;
        }
        final localFallback = _buildLocalPendingProjectData(pending);
        final merged = queuedPayload == null
            ? localFallback
            : _overlayPendingPayloadOnProjectData(
                baseData: localFallback,
                payload: queuedPayload,
              );
        _projectDataCache[projectId] =
            _ProjectDataCacheEntry(_deepCopyMap(merged), DateTime.now());
        return _deepCopyMap(merged);
      }

      // Fetch related data
      final partners = await _supabase
          .from('partners')
          .select()
          .eq('project_id', projectId)
          .order('created_at', ascending: true)
          .order('id', ascending: true);

      final expenses = await _supabase
          .from('expenses')
          .select()
          .eq('project_id', projectId)
          .order('created_at', ascending: true)
          .order('id', ascending: true);

      final nonSellableAreas = await _supabase
          .from('non_sellable_areas')
          .select()
          .eq('project_id', projectId);

      final amenityAreas = await _supabase
          .from('amenity_areas')
          .select()
          .eq('project_id', projectId)
          .order('sort_order', ascending: true)
          .order('created_at', ascending: true)
          .order('id', ascending: true);

      final layouts = await _supabase
          .from('layouts')
          .select()
          .eq('project_id', projectId)
          .order('created_at', ascending: true)
          .order('id', ascending: true);

      final projectManagers = await _supabase
          .from('project_managers')
          .select()
          .eq('project_id', projectId);

      final agents =
          await _supabase.from('agents').select().eq('project_id', projectId);

      // Fetch all plots for calculations in a single query.
      final layoutIds = layouts
          .map((layout) => (layout['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
      final plots = layoutIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(
              await _supabase
                  .from('plots')
                  .select()
                  .inFilter('layout_id', layoutIds)
                  .order('created_at', ascending: true)
                  .order('id', ascending: true),
            );
      final plotIds = plots
          .map((plot) => (plot['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList(growable: false);

      // Fetch plot_partners for all plots
      List<Map<String, dynamic>> plotPartners = [];
      if (plotIds.isNotEmpty) {
        plotPartners = await _supabase
            .from('plot_partners')
            .select('plot_id, partner_name')
            .inFilter('plot_id', plotIds);
      }

      // Calculate totals
      final totalArea = (project['total_area'] as num?)?.toDouble() ?? 0.0;
      final sellingArea = (project['selling_area'] as num?)?.toDouble() ?? 0.0;
      final estimatedCost =
          (project['estimated_development_cost'] as num?)?.toDouble() ?? 0.0;
      final nonSellableArea = nonSellableAreas.fold<double>(
        0.0,
        (sum, area) => sum + ((area['area'] as num?)?.toDouble() ?? 0.0),
      );

      // Calculate total expenses
      final totalExpenses = expenses.fold<double>(
        0.0,
        (sum, expense) =>
            sum + ((expense['amount'] as num?)?.toDouble() ?? 0.0),
      );

      // Calculate plot statistics
      final totalPlots = plots.length;
      final soldPlots = plots.where((p) => p['status'] == 'sold').length;
      final availablePlots =
          plots.where((p) => p['status'] == 'available').length;

      // Calculate all-in cost (weighted average per sqft)
      final totalPlotArea = plots.fold<double>(
        0.0,
        (sum, plot) => sum + ((plot['area'] as num?)?.toDouble() ?? 0.0),
      );
      final allInCostTotal = plots.fold<double>(
        0.0,
        (sum, plot) {
          final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
          final costPerSqft =
              ((plot['all_in_cost_per_sqft'] as num?)?.toDouble() ?? 0.0);
          return sum + (area * costPerSqft);
        },
      );
      final allInCost =
          totalPlotArea > 0 ? allInCostTotal / totalPlotArea : 0.0;

      // Calculate sales value
      final totalSalesValue =
          plots.where((p) => p['status'] == 'sold').fold<double>(
        0.0,
        (sum, plot) {
          final salePrice = ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
          final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
          return sum + (salePrice * area);
        },
      );

      // Calculate average sales price
      final totalSalePriceSum =
          plots.where((p) => p['status'] == 'sold').fold<double>(
                0.0,
                (sum, plot) =>
                    sum + ((plot['sale_price'] as num?)?.toDouble() ?? 0.0),
              );
      final avgSalesPrice = soldPlots > 0 ? totalSalePriceSum / soldPlots : 0.0;

      // Calculate compensation totals
      final totalPMCompensation = projectManagers.fold<double>(
        0.0,
        (sum, pm) => sum + ((pm['fee'] as num?)?.toDouble() ?? 0.0),
      );

      final totalAgentCompensation = agents.fold<double>(
        0.0,
        (sum, agent) => sum + ((agent['fee'] as num?)?.toDouble() ?? 0.0),
      );

      final totalCompensation = totalPMCompensation + totalAgentCompensation;

      // Calculate profitability metrics aligned with dashboard:
      // Gross Profit = Total Sales Value (sold plots) - Total Plot Cost (all plots)
      final grossProfit = totalSalesValue - allInCostTotal;
      final netProfit = grossProfit - totalCompensation;
      final profitMargin =
          totalSalesValue > 0 ? ((netProfit / totalSalesValue) * 100) : 0.0;
      final roi = estimatedCost > 0 ? ((netProfit / estimatedCost) * 100) : 0.0;

      // Compose result in the same structure as used in the report
      final result = {
        'projectName': project['project_name'],
        'projectStatus': project['project_status'],
        'projectAreaUnit': AreaUnitUtils.canonicalizeAreaUnit(
            project['area_unit']?.toString()),
        'projectAddress': project['project_address'] ?? project['address'],
        'googleMapsLink': project['google_maps_link'] ??
            project['maps_link'] ??
            project['location_link'],
        'totalArea': totalArea.toStringAsFixed(2),
        'sellingArea': sellingArea.toStringAsFixed(2),
        'estimatedDevelopmentCost': estimatedCost.toStringAsFixed(2),
        'nonSellableArea': nonSellableArea.toStringAsFixed(2),
        'allInCost': allInCost.toStringAsFixed(2),
        'totalExpenses': totalExpenses.toStringAsFixed(2),
        'totalLayouts': layouts.length,
        'totalPlots': totalPlots,
        'soldPlots': soldPlots,
        'availablePlots': availablePlots,
        'totalSalesValue': totalSalesValue.toStringAsFixed(2),
        'avgSalesPrice': avgSalesPrice.toStringAsFixed(2),
        'grossProfit': grossProfit.toStringAsFixed(2),
        'netProfit': netProfit.toStringAsFixed(2),
        'profitMargin': profitMargin.toStringAsFixed(2),
        'roi': roi.toStringAsFixed(2),
        'totalPMCompensation': totalPMCompensation.toStringAsFixed(2),
        'totalAgentCompensation': totalAgentCompensation.toStringAsFixed(2),
        'totalCompensation': totalCompensation.toStringAsFixed(2),
        'partners': partners,
        'expenses': expenses,
        'nonSellableAreas': nonSellableAreas,
        'amenityAreas': amenityAreas,
        'plots': plots,
        'layouts': layouts,
        'project_managers': projectManagers,
        'agents': agents,
        'plot_partners': plotPartners,
      };

      final merged = queuedPayload == null
          ? result
          : _overlayPendingPayloadOnProjectData(
              baseData: result,
              payload: queuedPayload,
            );
      _projectDataCache[projectId] =
          _ProjectDataCacheEntry(_deepCopyMap(merged), DateTime.now());
      return _deepCopyMap(merged);
    } catch (e) {
      _log('Error fetching project data: $e');
      final userId = await _resolveCurrentOrLastKnownUserId();
      if (userId != null && userId.trim().isNotEmpty) {
        final pending =
            await OfflineProjectSyncService.getPendingProjectEntryById(
          projectId,
          userId: userId,
        );
        if (pending != null) {
          final localFallback = _buildLocalPendingProjectData(pending);
          final merged = queuedPayload == null
              ? localFallback
              : _overlayPendingPayloadOnProjectData(
                  baseData: localFallback,
                  payload: queuedPayload,
                );
          _projectDataCache[projectId] = _ProjectDataCacheEntry(
            _deepCopyMap(merged),
            DateTime.now(),
          );
          return _deepCopyMap(merged);
        }
      }
      if (queuedPayload != null) {
        final synthetic = _buildLocalPendingProjectData(<String, dynamic>{
          'project_name': queuedPayload['projectName'] ?? '',
          'project_status': queuedPayload['projectStatus'] ?? 'Active',
          'area_unit': queuedPayload['projectAreaUnit'],
          'project_address': queuedPayload['projectAddress'] ?? '',
          'google_maps_link': queuedPayload['googleMapsLink'] ?? '',
        });
        final merged = _overlayPendingPayloadOnProjectData(
          baseData: synthetic,
          payload: queuedPayload,
        );
        _projectDataCache[projectId] = _ProjectDataCacheEntry(
          _deepCopyMap(merged),
          DateTime.now(),
        );
        return _deepCopyMap(merged);
      }
      return null;
    }
  }

  /// Save complete project data to Supabase
  static Future<void> saveProjectData({
    required String projectId,
    String? projectName,
    String? projectStatus,
    String? projectAreaUnit,
    String? projectAddress,
    String? googleMapsLink,
    String? totalArea,
    String? sellingArea,
    String? estimatedDevelopmentCost,
    List<Map<String, String>>? nonSellableAreas,
    List<Map<String, String>>? amenityAreas,
    List<Map<String, dynamic>>? partners,
    List<Map<String, dynamic>>? expenses,
    List<Map<String, dynamic>>? layouts,
    bool partialLayoutsSync = false,
    List<Map<String, dynamic>>? projectManagers,
    List<Map<String, dynamic>>? agents,
    bool allowOfflineQueue = true,
  }) async {
    final savePayload = _buildSavePayload(
      projectName: projectName,
      projectStatus: projectStatus,
      projectAreaUnit: projectAreaUnit,
      projectAddress: projectAddress,
      googleMapsLink: googleMapsLink,
      totalArea: totalArea,
      sellingArea: sellingArea,
      estimatedDevelopmentCost: estimatedDevelopmentCost,
      nonSellableAreas: nonSellableAreas,
      amenityAreas: amenityAreas,
      partners: partners,
      expenses: expenses,
      layouts: layouts,
      partialLayoutsSync: partialLayoutsSync,
      projectManagers: projectManagers,
      agents: agents,
    );
    try {
      _ensurePendingSaveSyncLoop();
      if (allowOfflineQueue) {
        await flushPendingSaves(projectId: projectId);
      }

      final userId = await _resolveCurrentOrLastKnownUserId();
      final normalizedUserId = (userId ?? '').trim();
      if (normalizedUserId.isEmpty) {
        if (allowOfflineQueue) {
          await _enqueuePendingSave(
            projectId: projectId,
            payload: savePayload,
            error: 'user_not_authenticated_local_queue',
          );
          throw ProjectSaveQueuedForSyncException(
            projectId: projectId,
            reason:
                'User session is unavailable. Changes were saved locally and queued for sync.',
          );
        }
        throw Exception('User not authenticated');
      }
      if (allowOfflineQueue) {
        final projectQueuedOffline =
            await OfflineProjectSyncService.isPendingLocalProject(
          projectId: projectId,
          userId: normalizedUserId,
        );
        if (projectQueuedOffline) {
          await _enqueuePendingSave(
            projectId: projectId,
            payload: savePayload,
            error: 'project create is still queued for sync',
          );
          throw ProjectSaveQueuedForSyncException(
            projectId: projectId,
            reason: 'Project is saved in your system and queued for sync',
          );
        }
      }

      // Get current project to check existing name
      final currentProject = await _supabase
          .from('projects')
          .select('project_name')
          .eq('id', projectId)
          .eq('user_id', normalizedUserId)
          .maybeSingle();

      // Build update map - only update fields if they are explicitly provided (not null/empty)
      // This prevents overwriting existing values when saving from other pages (e.g., plot_status_page)
      final updateData = <String, dynamic>{
        'updated_at': DateTime.now().toIso8601String(),
      };

      // Only update total_area if explicitly provided
      if (totalArea != null && totalArea.trim().isNotEmpty) {
        final parsedTotalArea = _parseDecimal(totalArea);
        updateData['total_area'] = parsedTotalArea;
        _log(
            'ProjectStorageService.saveProjectData: Updating total_area: "$totalArea" -> $parsedTotalArea');
      }

      // Only update selling_area if explicitly provided
      if (sellingArea != null && sellingArea.trim().isNotEmpty) {
        final parsedSellingArea = _parseDecimal(sellingArea);
        updateData['selling_area'] = parsedSellingArea;
        _log(
            'ProjectStorageService.saveProjectData: Updating selling_area: "$sellingArea" -> $parsedSellingArea');
      }

      // Only update estimated_development_cost if explicitly provided
      if (estimatedDevelopmentCost != null &&
          estimatedDevelopmentCost.trim().isNotEmpty) {
        final parsedEstimatedCost = _parseDecimal(estimatedDevelopmentCost);
        updateData['estimated_development_cost'] = parsedEstimatedCost;
        _log(
            'ProjectStorageService.saveProjectData: Updating estimated_development_cost: "$estimatedDevelopmentCost" -> $parsedEstimatedCost');
      }

      // Update status/address/location when explicitly provided.
      // Unlike numeric fields, empty string is valid here (user can clear address/link).
      if (projectStatus != null) {
        updateData['project_status'] = projectStatus.trim();
      }
      if (projectAreaUnit != null && projectAreaUnit.trim().isNotEmpty) {
        updateData['area_unit'] =
            AreaUnitUtils.canonicalizeAreaUnit(projectAreaUnit.trim());
      }
      if (projectAddress != null) {
        updateData['project_address'] = projectAddress.trim();
      }
      if (googleMapsLink != null) {
        updateData['google_maps_link'] = googleMapsLink.trim();
      }

      _log(
          'ProjectStorageService.saveProjectData: Update data map: $updateData');

      // Only update project_name if:
      // 1. It's not empty
      // 2. It's different from the current name
      // 3. It doesn't already exist for this user (unless it's the same project)
      final trimmedProjectName = projectName?.trim() ?? '';
      if (trimmedProjectName.isNotEmpty) {
        final currentName =
            currentProject?['project_name']?.toString().trim() ?? '';
        if (trimmedProjectName != currentName) {
          // Check if another project with this name exists for this user
          final existingProject = await _supabase
              .from('projects')
              .select('id')
              .eq('user_id', normalizedUserId)
              .eq('project_name', trimmedProjectName)
              .maybeSingle();

          // Only update if no other project has this name (or if it's the same project)
          if (existingProject == null || existingProject['id'] == projectId) {
            updateData['project_name'] = trimmedProjectName;
          }
          // If another project has this name, skip updating project_name to avoid duplicate key error
        }
      }

      // Update project basic info
      _log(
          'ProjectStorageService.saveProjectData: Updating project with data: $updateData');
      final updateResult = await _supabase
          .from('projects')
          .update(updateData)
          .eq('id', projectId)
          .eq('user_id', normalizedUserId)
          .select();
      if (updateResult is List && updateResult.isEmpty) {
        throw Exception('project_row_missing_for_sync');
      }
      _log(
          'ProjectStorageService.saveProjectData: Update result: $updateResult');

      final sectionErrors = <String>[];
      int attemptedSectionSaves = 0;
      int successfulSectionSaves = 0;

      // Save expenses first so dashboard totals stay fresh even when
      // unrelated sections (e.g., partners/layouts) fail validation.
      if (expenses != null) {
        attemptedSectionSaves++;
        try {
          await _saveExpenses(projectId, expenses);
          successfulSectionSaves++;
        } catch (e) {
          sectionErrors.add('expenses: $e');
        }
      }

      // Save non-sellable areas - only if explicitly provided.
      if (nonSellableAreas != null) {
        attemptedSectionSaves++;
        try {
          await _saveNonSellableAreas(projectId, nonSellableAreas);
          successfulSectionSaves++;
        } catch (e) {
          sectionErrors.add('non_sellable_areas: $e');
        }
      }

      // Save amenity areas - only if explicitly provided.
      if (amenityAreas != null) {
        attemptedSectionSaves++;
        try {
          await _saveAmenityAreas(projectId, amenityAreas);
          successfulSectionSaves++;
        } catch (e) {
          sectionErrors.add('amenity_areas: $e');
        }
      }

      // Save partners - only if explicitly provided (prevents deletion when
      // saving from other pages). If partners is null, do not modify them.
      if (partners != null) {
        attemptedSectionSaves++;
        try {
          await _savePartners(projectId, partners);
          successfulSectionSaves++;
        } catch (e) {
          sectionErrors.add('partners: $e');
        }
      }

      if (layouts != null) {
        attemptedSectionSaves++;
        try {
          await _saveLayoutsAndPlots(
            projectId,
            layouts,
            partialSync: partialLayoutsSync,
          );
          successfulSectionSaves++;
        } catch (e) {
          sectionErrors.add('layouts: $e');
        }
      }

      if (projectManagers != null) {
        attemptedSectionSaves++;
        try {
          await _saveProjectManagers(projectId, projectManagers);
          successfulSectionSaves++;
        } catch (e) {
          sectionErrors.add('project_managers: $e');
        }
      }

      if (agents != null) {
        attemptedSectionSaves++;
        try {
          await _saveAgents(projectId, agents);
          successfulSectionSaves++;
        } catch (e) {
          sectionErrors.add('agents: $e');
        }
      }

      if (sectionErrors.isNotEmpty) {
        final summary =
            'Project save failed for one or more sections (project=$projectId, attempted=$attemptedSectionSaves, successful=$successfulSectionSaves): ${sectionErrors.join(' | ')}';
        // IMPORTANT:
        // Do not swallow section failures. If any changed section fails (e.g.
        // partners), returning success causes false "Saved" state and data can
        // appear to vanish on reload because the failed section never persisted.
        throw Exception(summary);
      }

      invalidateProjectCache(projectId);
      await _markRemoteSaveTimestampForProject(projectId);
      if (allowOfflineQueue) {
        unawaited(flushPendingSaves());
      }
    } catch (e) {
      _log('Error saving project data: $e');
      if (allowOfflineQueue && _isLikelyNetworkError(e)) {
        await _enqueuePendingSave(
          projectId: projectId,
          payload: savePayload,
          error: e.toString(),
        );
        throw ProjectSaveQueuedForSyncException(
          projectId: projectId,
          reason: e.toString(),
        );
      }
      rethrow;
    }
  }

  static Future<void> _saveNonSellableAreas(
    String projectId,
    List<Map<String, String>> nonSellableAreas,
  ) async {
    // Delete existing non-sellable areas
    await _supabase
        .from('non_sellable_areas')
        .delete()
        .eq('project_id', projectId);

    // Insert new ones
    final areasToInsert = nonSellableAreas
        .where((area) => (area['name'] ?? '').trim().isNotEmpty)
        .map((area) => {
              'project_id': projectId,
              'name': area['name']?.trim() ?? '',
              'area': _parseDecimal(area['area']),
            })
        .toList();

    if (areasToInsert.isNotEmpty) {
      await _supabase.from('non_sellable_areas').insert(areasToInsert);
    }
  }

  static Future<void> _saveAmenityAreas(
    String projectId,
    List<Map<String, String>> amenityAreas,
  ) async {
    // Preserve amenity status/sales details by updating rows in-place when possible.
    // We match incoming rows by id first, then by normalized name as fallback.
    final existingRows = await _supabase
        .from('amenity_areas')
        .select('id, name')
        .eq('project_id', projectId)
        .order('sort_order', ascending: true)
        .order('created_at', ascending: true)
        .order('id', ascending: true);

    final existingById = <String, Map<String, dynamic>>{};
    final existingIdsByName = <String, List<String>>{};
    for (final row in existingRows) {
      final id = (row['id'] ?? '').toString().trim();
      if (!_looksLikeUuid(id)) continue;
      existingById[id] = row;
      final normalizedName =
          _normalizeUniqueName((row['name'] ?? '').toString());
      existingIdsByName.putIfAbsent(normalizedName, () => <String>[]).add(id);
    }

    final retainedIds = <String>{};
    final filtered = amenityAreas
        .where((area) => (area['name'] ?? '').trim().isNotEmpty)
        .toList();

    for (int index = 0; index < filtered.length; index++) {
      final area = filtered[index];
      final name = area['name']?.trim() ?? '';
      if (name.isEmpty) continue;

      final payload = <String, dynamic>{
        'name': name,
        'area': _parseDecimal(area['area']),
        'all_in_cost': _parseDecimal(area['allInCost']),
        'sort_order': index,
      };

      String? matchedId;
      final incomingId = (area['id'] ?? '').trim();
      if (_looksLikeUuid(incomingId) && existingById.containsKey(incomingId)) {
        matchedId = incomingId;
      } else {
        final normalizedName = _normalizeUniqueName(name);
        final nameMatches =
            existingIdsByName[normalizedName] ?? const <String>[];
        for (final candidateId in nameMatches) {
          if (!retainedIds.contains(candidateId)) {
            matchedId = candidateId;
            break;
          }
        }
      }

      if (matchedId != null) {
        await _supabase
            .from('amenity_areas')
            .update(payload)
            .eq('project_id', projectId)
            .eq('id', matchedId);
        retainedIds.add(matchedId);
      } else {
        await _supabase.from('amenity_areas').insert({
          'project_id': projectId,
          ...payload,
        });
      }
    }

    final existingIds = existingById.keys.toSet();
    final idsToDelete = existingIds.difference(retainedIds).toList();
    if (idsToDelete.isNotEmpty) {
      await _supabase
          .from('amenity_areas')
          .delete()
          .eq('project_id', projectId)
          .inFilter('id', idsToDelete);
    }
  }

  static Future<void> _savePartners(
    String projectId,
    List<Map<String, dynamic>> partners,
  ) async {
    // Safer strategy than delete-all + insert-all:
    // update existing rows by id, insert new rows, delete only rows that
    // were explicitly removed. This prevents data loss on mid-save refresh.
    final existingPartners = await _supabase
        .from('partners')
        .select('id, name')
        .eq('project_id', projectId);
    final existingIds = existingPartners
        .map((p) => (p['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    final existingIdByName = <String, String>{};
    for (final partner in existingPartners) {
      final id = (partner['id'] ?? '').toString().trim();
      final name = (partner['name'] ?? '').toString().trim();
      if (id.isEmpty || name.isEmpty) continue;
      existingIdByName[_normalizeUniqueName(name)] = id;
    }
    final retainedIds = <String>{};

    for (final partner in partners) {
      final name = partner['name']?.toString().trim() ?? '';
      final amount = _parseDecimal(partner['amount']?.toString());
      if (name.isEmpty && amount <= 0) {
        continue;
      }

      final partnerId = (partner['id'] ?? '').toString().trim();
      final normalizedName = _normalizeUniqueName(name);
      final existingIdForName = existingIdByName[normalizedName];
      final payload = {
        'name': name,
        'amount': amount,
      };

      if (partnerId.isNotEmpty) {
        // If user-entered row points to a different id but same partner name
        // already exists, merge into the existing row to avoid unique conflicts.
        if (existingIdForName != null && existingIdForName != partnerId) {
          await _supabase
              .from('partners')
              .update(payload)
              .eq('id', existingIdForName)
              .eq('project_id', projectId);
          retainedIds.add(existingIdForName);
        } else {
          await _supabase
              .from('partners')
              .update(payload)
              .eq('id', partnerId)
              .eq('project_id', projectId);
          retainedIds.add(partnerId);
          if (name.isNotEmpty) {
            existingIdByName[normalizedName] = partnerId;
          }
        }
      } else {
        // Prefer update-by-name when the partner already exists; insert only new names.
        if (existingIdForName != null) {
          await _supabase
              .from('partners')
              .update(payload)
              .eq('id', existingIdForName)
              .eq('project_id', projectId);
          retainedIds.add(existingIdForName);
        } else {
          final inserted = await _supabase
              .from('partners')
              .insert({
                'project_id': projectId,
                ...payload,
              })
              .select('id')
              .maybeSingle();
          final newId = (inserted?['id'] ?? '').toString();
          if (newId.isNotEmpty) {
            retainedIds.add(newId);
            if (name.isNotEmpty) {
              existingIdByName[normalizedName] = newId;
            }
          }
        }
      }
    }

    final idsToDelete = existingIds.difference(retainedIds);
    for (final id in idsToDelete) {
      await _supabase.from('partners').delete().eq('id', id);
    }
  }

  static Future<void> _saveExpenses(
    String projectId,
    List<Map<String, dynamic>> expenses,
  ) async {
    final expenseDateColumn = await _resolveExpenseDateColumnName();
    final expenseDocColumn = await _resolveExpenseDocColumnName();
    final expenseDocPathColumn = await _resolveExpenseDocPathColumnName();
    final expenseDocIdColumn = await _resolveExpenseDocIdColumnName();
    final expenseDocExtensionColumn =
        await _resolveExpenseDocExtensionColumnName();

    // Safer than delete-all + insert-all:
    // update existing rows by id, best-effort match rows missing id, insert only truly new rows,
    // then delete only rows explicitly removed.
    final existingExpenses = await _supabase
        .from('expenses')
        .select('id,item,amount,category,created_at')
        .eq('project_id', projectId);
    final existingRows =
        existingExpenses.map((row) => Map<String, dynamic>.from(row)).toList();
    final existingIds = existingRows
        .map((e) => (e['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    final existingById = <String, Map<String, dynamic>>{
      for (final row in existingRows)
        if ((row['id'] ?? '').toString().isNotEmpty)
          (row['id'] ?? '').toString(): row,
    };
    final unclaimedExistingIds = Set<String>.from(existingById.keys);
    final retainedIds = <String>{};

    String normText(dynamic value) => (value ?? '').toString().trim();
    String normAmount(dynamic value) {
      return _parseDecimal(value?.toString()).toStringAsFixed(2);
    }

    String? findBestExistingIdForMissingId({
      required String item,
      required String category,
      required String amountNorm,
    }) {
      // 1) Exact value match (item + category + amount).
      final exactMatches = unclaimedExistingIds.where((id) {
        final row = existingById[id];
        if (row == null) return false;
        return normText(row['item']) == item &&
            normText(row['category']) == category &&
            normAmount(row['amount']) == amountNorm;
      }).toList();
      if (exactMatches.isNotEmpty) return exactMatches.first;

      // 2) Fallback to item + category only if unique among unclaimed rows.
      final looseMatches = unclaimedExistingIds.where((id) {
        final row = existingById[id];
        if (row == null) return false;
        return normText(row['item']) == item &&
            normText(row['category']) == category;
      }).toList();
      if (looseMatches.length == 1) return looseMatches.first;
      return null;
    }

    for (final expense in expenses) {
      final item = normText(expense['item']);
      final category = normText(expense['category']);
      if (item.isEmpty || category.isEmpty) {
        continue;
      }

      final amountNorm = normAmount(expense['amount']);
      final payload = <String, dynamic>{
        'item': item,
        'amount': _parseDecimal(expense['amount']?.toString()),
        'category': category,
      };
      if (expenseDateColumn != null) {
        final expenseDate = (expense['expenseDate'] ??
                expense['expense_date'] ??
                expense['date'])
            ?.toString()
            .trim();
        payload[expenseDateColumn] =
            (expenseDate != null && expenseDate.isNotEmpty)
                ? _parseDate(expenseDate)
                : null;
      }
      if (expenseDocColumn != null) {
        final doc = (expense['doc'] ??
                expense['document'] ??
                expense['document_no'] ??
                expense['doc_no'] ??
                expense['invoice_no'] ??
                expense['receipt_no'])
            ?.toString()
            .trim();
        payload[expenseDocColumn] =
            (doc != null && doc.isNotEmpty) ? doc : null;
      }
      if (expenseDocPathColumn != null) {
        final docPath = (expense['docPath'] ??
                expense['doc_path'] ??
                expense['expense_doc_path'] ??
                expense['document_path'])
            ?.toString()
            .trim();
        payload[expenseDocPathColumn] =
            (docPath != null && docPath.isNotEmpty) ? docPath : null;
      }
      if (expenseDocIdColumn != null) {
        final docId = (expense['docId'] ??
                expense['doc_id'] ??
                expense['document_id'] ??
                expense['expense_document_id'])
            ?.toString()
            .trim();
        payload[expenseDocIdColumn] =
            (docId != null && _looksLikeUuid(docId)) ? docId : null;
      }
      if (expenseDocExtensionColumn != null) {
        final docExtension = (expense['docExtension'] ??
                expense['doc_extension'] ??
                expense['expense_doc_extension'] ??
                expense['document_extension'])
            ?.toString()
            .trim()
            .toLowerCase();
        payload[expenseDocExtensionColumn] =
            (docExtension != null && docExtension.isNotEmpty)
                ? docExtension
                : null;
      }

      final expenseId = (expense['id'] ?? '').toString().trim();
      final matchedExistingId = expenseId.isNotEmpty
          ? expenseId
          : findBestExistingIdForMissingId(
              item: item,
              category: category,
              amountNorm: amountNorm,
            );

      if (matchedExistingId != null && matchedExistingId.isNotEmpty) {
        await _supabase
            .from('expenses')
            .update(payload)
            .eq('id', matchedExistingId)
            .eq('project_id', projectId);
        retainedIds.add(matchedExistingId);
        unclaimedExistingIds.remove(matchedExistingId);
      } else {
        final inserted = await _supabase
            .from('expenses')
            .insert({
              'project_id': projectId,
              ...payload,
            })
            .select('id')
            .maybeSingle();
        final newId = (inserted?['id'] ?? '').toString();
        if (newId.isNotEmpty) {
          retainedIds.add(newId);
          // Keep in local working set so repeated rows in one payload won't reinsert.
          existingById[newId] = {
            'id': newId,
            'item': item,
            'amount': payload['amount'],
            'category': category,
          };
        }
      }
    }

    final idsToDelete = existingIds.difference(retainedIds);
    for (final id in idsToDelete) {
      await _supabase.from('expenses').delete().eq('id', id);
    }
  }

  static Future<void> _saveLayoutsAndPlots(
      String projectId, List<Map<String, dynamic>> layouts,
      {bool partialSync = false}) async {
    final errors = <String>[];
    final buyerContactColumnName = await _resolvePlotsBuyerContactColumnName();
    final supportsBuyerMobileNumber = await _supportsBuyerMobileNumberColumn();

    // Get existing layouts for this project
    final existingLayouts = await _supabase
        .from('layouts')
        .select('id, name')
        .eq('project_id', projectId);

    final existingLayoutMap = <String, String>{};
    final existingLayoutNameById = <String, String>{};
    for (var layout in existingLayouts) {
      final id = (layout['id'] ?? '').toString().trim();
      final name = (layout['name'] ?? '').toString().trim();
      if (name.isNotEmpty) {
        existingLayoutMap[name] = id;
      }
      if (id.isNotEmpty) {
        existingLayoutNameById[id] = name;
      }
    }

    // Process each layout
    for (var layoutData in layouts) {
      final layoutName = (layoutData['name'] ?? '').toString().trim();
      if (layoutName.isEmpty) continue;
      final incomingLayoutId = (layoutData['id'] ?? '').toString().trim();

      String layoutId;
      if (incomingLayoutId.isNotEmpty) {
        final existingById = await _supabase
            .from('layouts')
            .select('id')
            .eq('project_id', projectId)
            .eq('id', incomingLayoutId)
            .maybeSingle();
        if (existingById != null && existingById['id'] != null) {
          layoutId = (existingById['id'] ?? '').toString();
          if (layoutName.isNotEmpty) {
            existingLayoutMap[layoutName] = layoutId;
          }
        } else if (existingLayoutMap.containsKey(layoutName)) {
          layoutId = existingLayoutMap[layoutName]!;
        } else {
          // Fallback to create/find by name when incoming id does not exist.
          layoutId = '';
        }
      } else if (existingLayoutMap.containsKey(layoutName)) {
        layoutId = existingLayoutMap[layoutName]!;
      } else {
        layoutId = '';
      }

      if (layoutId.isEmpty) {
        // Check if layout already exists (handle race condition)
        try {
          final existingCheck = await _supabase
              .from('layouts')
              .select('id')
              .eq('project_id', projectId)
              .eq('name', layoutName)
              .maybeSingle();

          if (existingCheck != null && existingCheck['id'] != null) {
            layoutId = existingCheck['id'];
            existingLayoutMap[layoutName] =
                layoutId; // Update map for future reference
          } else {
            // Create new layout
            final newLayout = await _supabase
                .from('layouts')
                .insert({
                  'project_id': projectId,
                  'name': layoutName,
                })
                .select()
                .single();
            layoutId = newLayout['id'];
            existingLayoutMap[layoutName] =
                layoutId; // Update map for future reference
          }
        } catch (e) {
          // If insert fails due to duplicate key, try to fetch existing
          if (e.toString().contains('duplicate key') ||
              e.toString().contains('23505')) {
            final existingCheck = await _supabase
                .from('layouts')
                .select('id')
                .eq('project_id', projectId)
                .eq('name', layoutName)
                .maybeSingle();
            if (existingCheck != null && existingCheck['id'] != null) {
              layoutId = existingCheck['id'];
              existingLayoutMap[layoutName] = layoutId;
            } else {
              final msg = 'Error: Could not find or create layout: $layoutName';
              _log(msg);
              errors.add(msg);
              continue; // Skip this layout
            }
          } else {
            rethrow;
          }
        }
      }

      final previousLayoutName = existingLayoutNameById[layoutId] ?? '';
      final isLayoutRenamed = previousLayoutName.trim().isNotEmpty &&
          previousLayoutName.trim() != layoutName;
      if (isLayoutRenamed) {
        try {
          await _supabase
              .from('layouts')
              .update({'name': layoutName}).eq('id', layoutId);
        } catch (e) {
          _log(
              '_saveLayoutsAndPlots: failed to update layout name "$previousLayoutName" -> "$layoutName": $e');
        }

        // Keep name maps consistent so renamed layouts are not accidentally
        // treated as stale and deleted at the end of save.
        if (existingLayoutMap[previousLayoutName] == layoutId) {
          existingLayoutMap.remove(previousLayoutName);
        }
        existingLayoutMap[layoutName] = layoutId;
        existingLayoutNameById[layoutId] = layoutName;

        await _syncLayoutDocumentsFolderName(
          projectId: projectId,
          layoutId: layoutId,
          layoutName: layoutName,
          previousLayoutName: previousLayoutName,
        );
      } else {
        existingLayoutMap[layoutName] = layoutId;
        existingLayoutNameById[layoutId] = layoutName;
      }

      try {
        final layoutImageName =
            (layoutData['layoutImageName'] ?? '').toString().trim();
        final layoutImagePath =
            (layoutData['layoutImagePath'] ?? '').toString().trim();
        final layoutImageDocId =
            (layoutData['layoutImageDocId'] ?? '').toString().trim();
        final layoutImageExtension =
            (layoutData['layoutImageExtension'] ?? '').toString().trim();
        final hasLayoutImageMeta = layoutData.containsKey('layoutImageName') ||
            layoutData.containsKey('layoutImagePath') ||
            layoutData.containsKey('layoutImageDocId') ||
            layoutData.containsKey('layoutImageExtension');
        if (hasLayoutImageMeta) {
          await _supabase.from('layouts').update({
            'layout_image_name':
                layoutImageName.isEmpty ? null : layoutImageName,
            'layout_image_path':
                layoutImagePath.isEmpty ? null : layoutImagePath,
            'layout_image_doc_id':
                _looksLikeUuid(layoutImageDocId) ? layoutImageDocId : null,
            'layout_image_extension':
                layoutImageExtension.isEmpty ? null : layoutImageExtension,
          }).eq('id', layoutId);
        }
      } catch (e) {
        // This can fail before the DB migration is applied. Continue safely.
        _log(
            '_saveLayoutsAndPlots: layout image metadata sync skipped for "$layoutName": $e');
      }

      // Get plots for this layout
      final plots = layoutData['plots'] as List<dynamic>? ?? [];
      final incomingNonEmptyPlotNumbers = plots
          .map((plotData) => (plotData is Map
                  ? (plotData['plotNumber'] ?? '').toString().trim()
                  : '')
              .toString()
              .trim())
          .where((plotNumber) => plotNumber.isNotEmpty)
          .toSet();
      final hasIncomingNonEmptyPlots = incomingNonEmptyPlotNumbers.isNotEmpty;

      final existingPlots = await _supabase
          .from('plots')
          .select('id, plot_number')
          .eq('layout_id', layoutId);
      final existingPlotIdByNumber = <String, String>{};
      for (final row in existingPlots) {
        final existingPlotId = (row['id'] ?? '').toString().trim();
        final existingPlotNumber =
            (row['plot_number'] ?? '').toString().trim().toLowerCase();
        if (existingPlotId.isNotEmpty && existingPlotNumber.isNotEmpty) {
          existingPlotIdByNumber[existingPlotNumber] = existingPlotId;
        }
      }
      final retainedPlotIds = <String>{};
      var layoutHadPlotSaveError = false;

      // Insert/update plots
      int insertedPlotIndex = 0; // Track first plot for debug logging
      for (int plotIndex = 0; plotIndex < plots.length; plotIndex++) {
        final plotData = plots[plotIndex];
        final plotNumber = (plotData['plotNumber'] ?? '').toString().trim();
        if (plotNumber.isEmpty) continue; // Skip empty plots

        try {
          final purchaseRate = plotData['purchaseRate']?.toString() ?? '0.00';
          final allInCostPerSqft = _parseDecimal(purchaseRate);
          final totalPlotCost =
              _parseDecimal(plotData['totalPlotCost']?.toString());

          // Debug logging for first plot only
          if (insertedPlotIndex == 0) {
            _log(
                'Saving plot: plotNumber=$plotNumber, purchaseRate=$purchaseRate, allInCostPerSqft=$allInCostPerSqft, totalPlotCost=$totalPlotCost');
          }

          // Debug payments data
          final paymentsData = plotData['payments'];
          _log(
              'DEBUG PAYMENTS: Plot $plotNumber - payments type: ${paymentsData.runtimeType}, payments value: $paymentsData');

          final paymentsRaw = plotData['payments'] as List<dynamic>? ?? [];
          final paymentsToSave = paymentsRaw
              .map((payment) {
                if (payment is Map<String, dynamic>) {
                  return Map<String, dynamic>.from(payment);
                }
                if (payment is Map) {
                  return Map<String, dynamic>.from(
                      payment.cast<String, dynamic>());
                }
                return <String, dynamic>{};
              })
              .where((p) => p.isNotEmpty)
              .toList();

          Map<String, dynamic> plotDataToSave = {
            'layout_id': layoutId,
            'plot_number': plotNumber,
            'area': _parseDecimal(plotData['area']?.toString()),
            'all_in_cost_per_sqft': allInCostPerSqft,
            'total_plot_cost': totalPlotCost,
            'status': _normalizePlotStatusForDatabase(plotData['status']),
            'sale_price': plotData['salePrice'] != null &&
                    plotData['salePrice'].toString().trim().isNotEmpty
                ? _parseDecimal(plotData['salePrice']?.toString())
                : null,
            'buyer_name': plotData['buyerName'] != null &&
                    plotData['buyerName'].toString().trim().isNotEmpty
                ? plotData['buyerName'].toString().trim()
                : null,
            'sale_date': plotData['saleDate'] != null &&
                    plotData['saleDate'].toString().trim().isNotEmpty
                ? _parseDate(plotData['saleDate']?.toString())
                : null,
            'agent_name': plotData['agent'] != null &&
                    plotData['agent'].toString().trim().isNotEmpty
                ? plotData['agent'].toString().trim()
                : null,
            'payments': paymentsToSave,
          };

          if (buyerContactColumnName != null &&
              plotData is Map &&
              (plotData.containsKey('buyerContactNumber') ||
                  plotData.containsKey('buyer_contact_number') ||
                  plotData.containsKey('buyer_mobile_number'))) {
            final rawBuyerContact = (plotData['buyerContactNumber'] ??
                    plotData['buyer_contact_number'] ??
                    plotData['buyer_mobile_number'] ??
                    '')
                .toString()
                .trim();
            plotDataToSave[buyerContactColumnName] =
                rawBuyerContact.isEmpty ? null : rawBuyerContact;
            if (supportsBuyerMobileNumber &&
                buyerContactColumnName != 'buyer_mobile_number') {
              plotDataToSave['buyer_mobile_number'] =
                  rawBuyerContact.isEmpty ? null : rawBuyerContact;
            }
          }

          final incomingPlotId =
              (plotData is Map ? (plotData['id'] ?? '').toString().trim() : '');
          final fallbackExistingPlotId =
              existingPlotIdByNumber[plotNumber.toLowerCase()] ?? '';
          final targetPlotId = incomingPlotId.isNotEmpty
              ? incomingPlotId
              : (fallbackExistingPlotId.isNotEmpty
                  ? fallbackExistingPlotId
                  : '');
          Map<String, dynamic> newPlot;
          if (targetPlotId.isNotEmpty) {
            newPlot = await _supabase
                .from('plots')
                .update(plotDataToSave)
                .eq('id', targetPlotId)
                .eq('layout_id', layoutId)
                .select()
                .single();
          } else {
            newPlot = await _supabase
                .from('plots')
                .upsert(
                  plotDataToSave,
                  onConflict: 'layout_id,plot_number',
                )
                .select()
                .single();
          }

          insertedPlotIndex++; // Increment only for successfully inserted plots

          final plotId = (newPlot['id'] ?? '').toString();
          if (plotId.isNotEmpty) {
            retainedPlotIds.add(plotId);
          }

          // Save plot partners only when caller explicitly sends this field.
          // This avoids accidental partner deletion when saving from pages that
          // don't include partner data in their layout payload.
          final hasPartnersField =
              plotData is Map && plotData.containsKey('partners');
          if (hasPartnersField) {
            final plotPartners = plotData['partners'] as List<dynamic>? ?? [];
            final desiredPartners = plotPartners
                .map((p) => p.toString().trim())
                .where((p) => p.isNotEmpty)
                .toSet();
            _log(
                'DEBUG ProjectStorageService: Saving partners for plot ${newPlot['plot_number']}: $plotPartners (${plotPartners.length} partners)');

            final existingPartnerRows = await _supabase
                .from('plot_partners')
                .select('partner_name')
                .eq('plot_id', plotId);
            final existingPartners = existingPartnerRows
                .map((row) => (row['partner_name'] ?? '').toString().trim())
                .where((p) => p.isNotEmpty)
                .toSet();

            final partnersToInsert =
                desiredPartners.difference(existingPartners).toList();
            if (partnersToInsert.isNotEmpty) {
              final rows = partnersToInsert
                  .map((partnerName) => {
                        'plot_id': plotId,
                        'partner_name': partnerName,
                      })
                  .toList();
              _log(
                  'DEBUG ProjectStorageService: Inserting ${rows.length} partners into plot_partners table');
              await _supabase.from('plot_partners').insert(rows);
            }

            final partnersToDelete =
                existingPartners.difference(desiredPartners).toList();
            for (final partnerName in partnersToDelete) {
              await _supabase
                  .from('plot_partners')
                  .delete()
                  .eq('plot_id', plotId)
                  .eq('partner_name', partnerName);
            }
          } else {
            _log(
                'DEBUG ProjectStorageService: Skipping partner update for plot ${newPlot['plot_number']} (partners field not provided)');
          }
        } catch (e) {
          final msg = 'Error saving plot $plotNumber: $e';
          _log(msg);
          errors.add(msg);
          layoutHadPlotSaveError = true;
          continue;
        }
      }

      // Full sync deletes missing plots. Partial sync skips deletes by design.
      if (!partialSync && !layoutHadPlotSaveError && hasIncomingNonEmptyPlots) {
        for (final existingPlot in existingPlots) {
          final existingPlotId = (existingPlot['id'] ?? '').toString();
          if (existingPlotId.isNotEmpty &&
              !retainedPlotIds.contains(existingPlotId)) {
            final existingPlotNumber =
                (existingPlot['plot_number'] ?? '').toString().trim();
            _log(
                'Deleting plot removed from layout $layoutId: $existingPlotNumber');
            await _supabase.from('plots').delete().eq('id', existingPlotId);
          }
        }
      } else if (!hasIncomingNonEmptyPlots) {
        _log(
            '_saveLayoutsAndPlots: Skipping plot deletions for layout "$layoutName" because incoming payload has no non-empty plot numbers');
      } else if (!partialSync) {
        final msg =
            '_saveLayoutsAndPlots: Skipping plot deletions for layout "$layoutName" due to save errors';
        _log(msg);
        errors.add(msg);
      }
    }

    if (!partialSync) {
      // Delete layouts that are no longer in the full payload.
      final currentLayoutNames = layouts
          .map((l) => (l['name'] ?? '').toString().trim())
          .where((n) => n.isNotEmpty)
          .toSet();
      final layoutsToDelete = existingLayoutMap.entries
          .where((e) => !currentLayoutNames.contains(e.key))
          .map((e) => e.value)
          .toList();

      _log('_saveLayoutsAndPlots: Current layout names: $currentLayoutNames');
      _log('_saveLayoutsAndPlots: Existing layout map: $existingLayoutMap');
      _log(
          '_saveLayoutsAndPlots: Layouts to delete: ${layoutsToDelete.length}');

      if (layoutsToDelete.isNotEmpty) {
        for (var layoutId in layoutsToDelete) {
          _log('Deleting layout: $layoutId');
          await _supabase.from('layouts').delete().eq('id', layoutId);
        }
      }
    }

    if (errors.isNotEmpty) {
      throw Exception(
          '_saveLayoutsAndPlots failed with ${errors.length} error(s). First error: ${errors.first}');
    }
  }

  static Future<void> _saveProjectManagers(
    String projectId,
    List<Map<String, dynamic>> projectManagers,
  ) async {
    _log(
        '_saveProjectManagers: Saving ${projectManagers.length} project managers for project $projectId');

    // Get existing project managers to determine which ones to delete later
    final existingManagers = await _supabase
        .from('project_managers')
        .select('id, name')
        .eq('project_id', projectId);
    final existingManagerIds =
        existingManagers.map((m) => m['id'] as String).toSet();
    final existingManagerIdByName = <String, String>{};
    for (final manager in existingManagers) {
      final id = manager['id']?.toString();
      final name = (manager['name'] ?? '').toString().trim().toLowerCase();
      if (id == null || name.isEmpty) continue;
      existingManagerIdByName[name] = id;
    }
    final processedManagerIds = <String>{};

    // Deduplicate project managers by ID before saving to prevent duplicates
    final seenIds = <String>{};
    final uniqueManagers = <Map<String, dynamic>>[];
    for (var managerData in projectManagers) {
      final id = managerData['id']?.toString();
      if (id != null && seenIds.contains(id)) {
        _log('_saveProjectManagers: Skipping duplicate manager with id=$id');
        continue;
      }
      if (id != null) {
        seenIds.add(id);
      }
      uniqueManagers.add(managerData);
    }

    _log(
        '_saveProjectManagers: After deduplication: ${uniqueManagers.length} unique managers (original: ${projectManagers.length})');

    // Get existing managers with their created_at to preserve order
    final existingManagersWithDates = await _supabase
        .from('project_managers')
        .select('id, created_at')
        .eq('project_id', projectId)
        .order('created_at', ascending: true);
    final existingManagerDates = <String, DateTime>{};
    DateTime? latestExistingDate;
    for (var m in existingManagersWithDates) {
      final id = m['id']?.toString();
      final createdAt = m['created_at'];
      if (id != null && createdAt != null) {
        try {
          final date = DateTime.parse(createdAt.toString());
          existingManagerDates[id] = date;
          if (latestExistingDate == null || date.isAfter(latestExistingDate)) {
            latestExistingDate = date;
          }
        } catch (e) {
          _log(
              '_saveProjectManagers: Error parsing created_at for manager $id: $e');
        }
      }
    }

    // Process managers: update existing ones, insert new ones with preserved order
    // For new managers, start timestamps after the latest existing manager
    final errors = <String>[];
    final baseTime = latestExistingDate != null
        ? latestExistingDate.add(Duration(seconds: 1))
        : DateTime.now();
    int insertedManagerIndex =
        0; // Track actual inserted managers for timestamp ordering

    for (var managerData in uniqueManagers) {
      final name = (managerData['name'] ?? '').toString().trim();
      if (name.isEmpty) {
        _log('_saveProjectManagers: Skipping manager with empty name');
        continue;
      }

      final compensationType = managerData['compensation']?.toString();
      final earningType = managerData['earningType']?.toString();

      _log(
          '_saveProjectManagers: Processing manager "$name": compensation="$compensationType", earningType="$earningType"');

      // Convert empty strings to null, but keep valid values (including 'None')
      final finalCompensationType =
          (compensationType == null || compensationType.trim().isEmpty)
              ? 'None'
              : compensationType.trim();

      // Map UI earning type values to database values
      // Map UI earning type values to DB allowed values (Per Plot, Per Square Foot, Lump Sum)
      // Constraint requires earning_type to be null for non-percentage bonus rows
      final String? finalEarningType =
          finalCompensationType == 'Percentage Bonus'
              ? _mapEarningType(earningType)
              : null;

      _log(
          '_saveProjectManagers: Mapped values: compensation_type="$finalCompensationType", earning_type="$finalEarningType"');

      String? managerId = managerData['id']?.toString();
      if (managerId == null || managerId.trim().isEmpty) {
        managerId = existingManagerIdByName[name.toLowerCase()];
        if (managerId != null) {
          _log(
              '_saveProjectManagers: Matched manager "$name" to existing id=$managerId by name');
        }
      }
      final isNewManager =
          managerId == null || !existingManagerIds.contains(managerId);

      String finalManagerId;

      try {
        if (isNewManager) {
          // Insert new manager with sequential created_at to preserve order
          final managerTimestamp =
              baseTime.add(Duration(milliseconds: insertedManagerIndex * 10));
          final newManager = await _supabase
              .from('project_managers')
              .insert({
                'project_id': projectId,
                'name': name,
                'compensation_type': finalCompensationType,
                'earning_type': finalEarningType,
                'percentage': finalCompensationType == 'Percentage Bonus'
                    ? _parseDecimal(managerData['percentage']?.toString())
                    : null,
                'fixed_fee': finalCompensationType == 'Fixed Fee'
                    ? _parseDecimal(managerData['fixedFee']?.toString())
                    : null,
                'monthly_fee': finalCompensationType == 'Monthly Fee'
                    ? _parseDecimal(managerData['monthlyFee']?.toString())
                    : null,
                'months': finalCompensationType == 'Monthly Fee'
                    ? _parseInt(managerData['months']?.toString())
                    : null,
                'created_at': managerTimestamp.toIso8601String(),
              })
              .select()
              .single();
          finalManagerId = newManager['id'] as String;
          processedManagerIds.add(finalManagerId);
          existingManagerIds.add(finalManagerId);
          existingManagerIdByName[name.toLowerCase()] = finalManagerId;
          insertedManagerIndex++;
          _log(
              '_saveProjectManagers: Successfully inserted new manager: $newManager');
        } else {
          // Update existing manager - DO NOT touch created_at to preserve original order
          await _supabase.from('project_managers').update({
            'name': name,
            'compensation_type': finalCompensationType,
            'earning_type': finalEarningType,
            'percentage': finalCompensationType == 'Percentage Bonus'
                ? _parseDecimal(managerData['percentage']?.toString())
                : null,
            'fixed_fee': finalCompensationType == 'Fixed Fee'
                ? _parseDecimal(managerData['fixedFee']?.toString())
                : null,
            'monthly_fee': finalCompensationType == 'Monthly Fee'
                ? _parseDecimal(managerData['monthlyFee']?.toString())
                : null,
            'months': finalCompensationType == 'Monthly Fee'
                ? _parseInt(managerData['months']?.toString())
                : null,
            // Explicitly do NOT update created_at to preserve original order
          }).eq('id', managerId);
          finalManagerId = managerId;
          processedManagerIds.add(finalManagerId);
          existingManagerIdByName[name.toLowerCase()] = finalManagerId;
          _log(
              '_saveProjectManagers: Successfully updated existing manager: id=$managerId');
        }

        // Save selected blocks/plots (always delete existing blocks and re-insert for this manager).
        // Block-link failures should not fail manager row persistence.
        try {
          await _supabase
              .from('project_manager_blocks')
              .delete()
              .eq('project_manager_id', finalManagerId);

          final selectedBlocks =
              managerData['selectedBlocks'] as List<dynamic>? ?? [];
          if (selectedBlocks.isNotEmpty) {
            final layouts = await _supabase
                .from('layouts')
                .select('id, name')
                .eq('project_id', projectId);

            final plotIdsToInsert = <String>[];
            for (var blockString in selectedBlocks) {
              final block = blockString.toString().trim();
              if (block.isEmpty) continue;

              final parts = block.split(' - ');
              if (parts.length != 2) continue;

              final layoutName = parts[0].trim();
              final plotIdentifier = parts[1].trim();

              final layout = layouts.firstWhere(
                (l) => (l['name'] ?? '').toString().trim() == layoutName,
                orElse: () => <String, dynamic>{},
              );

              if (layout.isEmpty || layout['id'] == null) continue;
              final layoutId = layout['id'];

              if (plotIdentifier.startsWith('Plot ')) {
                final plotIndexStr =
                    plotIdentifier.replaceAll('Plot ', '').trim();
                final plotIndex = int.tryParse(plotIndexStr);
                if (plotIndex != null) {
                  final plots = await _supabase
                      .from('plots')
                      .select('id')
                      .eq('layout_id', layoutId)
                      .order('plot_number');
                  if (plotIndex > 0 && plotIndex <= plots.length) {
                    plotIdsToInsert.add(plots[plotIndex - 1]['id']);
                  }
                }
              } else {
                final plots = await _supabase
                    .from('plots')
                    .select('id')
                    .eq('layout_id', layoutId)
                    .eq('plot_number', plotIdentifier);
                if (plots.isNotEmpty) {
                  plotIdsToInsert.add(plots[0]['id']);
                }
              }
            }

            if (plotIdsToInsert.isNotEmpty) {
              final blocksToInsert = plotIdsToInsert
                  .map((plotId) => {
                        'project_manager_id': finalManagerId,
                        'plot_id': plotId,
                      })
                  .toList();
              await _supabase
                  .from('project_manager_blocks')
                  .insert(blocksToInsert);
            }
          }
        } catch (e) {
          _log(
              '_saveProjectManagers: Warning: failed to save blocks for manager "$name" (id=$finalManagerId): $e');
        }
      } catch (e) {
        final errorMsg =
            '_saveProjectManagers: Error upserting manager "$name": $e';
        _log(errorMsg);
        errors.add(errorMsg);
        // Continue processing remaining managers instead of stopping
        continue;
      }
    }

    // Log any errors that occurred
    if (errors.isNotEmpty) {
      _log(
          '_saveProjectManagers: ${errors.length} error(s) occurred while saving managers:');
      for (var error in errors) {
        _log('  - $error');
      }
      _log(
          '_saveProjectManagers: Skipping deletion of existing managers due save errors to prevent data loss');
      throw Exception(
          '_saveProjectManagers failed with ${errors.length} error(s). First error: ${errors.first}');
    }

    _log(
        '_saveProjectManagers: Successfully processed ${processedManagerIds.length} managers');

    // Delete project managers that were removed (present in DB but not in processed list)
    final idsToDelete = existingManagerIds.difference(processedManagerIds);
    if (idsToDelete.isNotEmpty) {
      for (var managerId in idsToDelete) {
        // Delete blocks first
        await _supabase
            .from('project_manager_blocks')
            .delete()
            .eq('project_manager_id', managerId);

        // Delete manager
        await _supabase.from('project_managers').delete().eq('id', managerId);
      }
    }
  }

  static Future<void> _saveAgents(
    String projectId,
    List<Map<String, dynamic>> agents,
  ) async {
    _log('_saveAgents: Saving ${agents.length} agents for project $projectId');

    // Get existing agents to determine which ones to delete later
    final existingAgents = await _supabase
        .from('agents')
        .select('id, name')
        .eq('project_id', projectId);
    final existingAgentIds =
        existingAgents.map((a) => a['id'] as String).toSet();
    final existingAgentIdByName = <String, String>{};
    for (final agent in existingAgents) {
      final id = agent['id']?.toString();
      final name = (agent['name'] ?? '').toString().trim().toLowerCase();
      if (id == null || name.isEmpty) continue;
      existingAgentIdByName[name] = id;
    }
    final processedAgentIds = <String>{};

    // Upsert new/updated agents
    final errors = <String>[];
    for (var agentData in agents) {
      final name = (agentData['name'] ?? '').toString().trim();
      if (name.isEmpty) {
        _log('_saveAgents: Skipping agent with empty name');
        continue;
      }

      final compensationType = agentData['compensation']?.toString();
      final earningType = agentData['earningType']?.toString();
      final percentage = agentData['percentage']?.toString();
      final fixedFee = agentData['fixedFee']?.toString();
      final monthlyFee = agentData['monthlyFee']?.toString();
      final months = agentData['months']?.toString();
      final perSqftFee = agentData['perSqftFee']?.toString();

      _log(
          '_saveAgents: Processing agent "$name": compensation="$compensationType", earningType="$earningType", percentage="$percentage", fixedFee="$fixedFee", monthlyFee="$monthlyFee", months="$months", perSqftFee="$perSqftFee"');

      // Convert empty strings to null, but keep valid values (including 'None')
      final finalCompensationType =
          (compensationType == null || compensationType.trim().isEmpty)
              ? 'None'
              : compensationType.trim();

      // Map UI earning type values to database values
      // Map UI earning type values to DB allowed values (Per Plot, Per Square Foot, Lump Sum)
      // Constraint requires earning_type to be null for non-percentage bonus rows
      final String? finalEarningType =
          finalCompensationType == 'Percentage Bonus'
              ? _mapEarningType(earningType)
              : null;

      _log(
          '_saveAgents: Mapped values: compensation_type="$finalCompensationType", earning_type="$finalEarningType"');

      final dataToUpsert = {
        'project_id': projectId,
        'name': name,
        'compensation_type': finalCompensationType,
        'earning_type': finalEarningType,
        'percentage': finalCompensationType == 'Percentage Bonus'
            ? _parseDecimal(percentage)
            : null,
        'fixed_fee': finalCompensationType == 'Fixed Fee'
            ? _parseDecimal(fixedFee)
            : null,
        'monthly_fee': finalCompensationType == 'Monthly Fee'
            ? _parseDecimal(monthlyFee)
            : null,
        'months':
            finalCompensationType == 'Monthly Fee' ? _parseInt(months) : null,
        'per_sqft_fee': finalCompensationType == 'Per Sqft Fee'
            ? _parseDecimal(perSqftFee)
            : null,
      };

      _log('_saveAgents: Data to upsert: $dataToUpsert');

      // If ID exists, add it to update existing record.
      // If UI row has no id, match by name to avoid duplicate inserts.
      String? agentId = agentData['id']?.toString();
      if (agentId == null || agentId.trim().isEmpty) {
        agentId = existingAgentIdByName[name.toLowerCase()];
        if (agentId != null) {
          _log(
              '_saveAgents: Matched agent "$name" to existing id=$agentId by name');
        }
      }
      if (agentId != null && agentId.isNotEmpty) {
        dataToUpsert['id'] = agentId;
      }

      try {
        final upsertedAgent = await _supabase
            .from('agents')
            .upsert(dataToUpsert)
            .select()
            .single();
        _log('_saveAgents: Successfully upserted agent: $upsertedAgent');

        final savedAgentId = upsertedAgent['id'] as String;
        processedAgentIds.add(savedAgentId);
        existingAgentIds.add(savedAgentId);
        existingAgentIdByName[name.toLowerCase()] = savedAgentId;

        // Save selected blocks/plots (always delete existing blocks and re-insert for this agent).
        // Block-link failures should not fail agent row persistence.
        try {
          await _supabase
              .from('agent_blocks')
              .delete()
              .eq('agent_id', savedAgentId);

          final selectedBlocks =
              agentData['selectedBlocks'] as List<dynamic>? ?? [];
          if (selectedBlocks.isNotEmpty) {
            final layouts = await _supabase
                .from('layouts')
                .select('id, name')
                .eq('project_id', projectId);

            final plotIdsToInsert = <String>[];
            for (var blockString in selectedBlocks) {
              final block = blockString.toString().trim();
              if (block.isEmpty) continue;

              final parts = block.split(' - ');
              if (parts.length != 2) continue;

              final layoutName = parts[0].trim();
              final plotIdentifier = parts[1].trim();

              final layout = layouts.firstWhere(
                (l) => (l['name'] ?? '').toString().trim() == layoutName,
                orElse: () => <String, dynamic>{},
              );

              if (layout.isEmpty || layout['id'] == null) continue;
              final layoutId = layout['id'];

              if (plotIdentifier.startsWith('Plot ')) {
                final plotIndexStr =
                    plotIdentifier.replaceAll('Plot ', '').trim();
                final plotIndex = int.tryParse(plotIndexStr);
                if (plotIndex != null) {
                  final plots = await _supabase
                      .from('plots')
                      .select('id')
                      .eq('layout_id', layoutId)
                      .order('plot_number');
                  if (plotIndex > 0 && plotIndex <= plots.length) {
                    plotIdsToInsert.add(plots[plotIndex - 1]['id']);
                  }
                }
              } else {
                final plots = await _supabase
                    .from('plots')
                    .select('id')
                    .eq('layout_id', layoutId)
                    .eq('plot_number', plotIdentifier);
                if (plots.isNotEmpty) {
                  plotIdsToInsert.add(plots[0]['id']);
                }
              }
            }

            if (plotIdsToInsert.isNotEmpty) {
              final blocksToInsert = plotIdsToInsert
                  .map((plotId) => {
                        'agent_id': savedAgentId,
                        'plot_id': plotId,
                      })
                  .toList();
              await _supabase.from('agent_blocks').insert(blocksToInsert);
            }
          }
        } catch (e) {
          _log(
              '_saveAgents: Warning: failed to save blocks for agent "$name" (id=$savedAgentId): $e');
        }
      } catch (e) {
        final errorMsg = '_saveAgents: Error upserting agent "$name": $e';
        _log(errorMsg);
        errors.add(errorMsg);
        // Continue processing remaining agents instead of stopping
        continue;
      }
    }

    // Log any errors that occurred
    if (errors.isNotEmpty) {
      _log(
          '_saveAgents: ${errors.length} error(s) occurred while saving agents:');
      for (var error in errors) {
        _log('  - $error');
      }
      _log(
          '_saveAgents: Skipping deletion of existing agents due save errors to prevent data loss');
      throw Exception(
          '_saveAgents failed with ${errors.length} error(s). First error: ${errors.first}');
    }

    _log(
        '_saveAgents: Successfully processed ${processedAgentIds.length} agents');

    // Delete agents that were removed (present in DB but not in processed list)
    final idsToDelete = existingAgentIds.difference(processedAgentIds);
    if (idsToDelete.isNotEmpty) {
      for (var agentId in idsToDelete) {
        // Delete blocks first
        await _supabase.from('agent_blocks').delete().eq('agent_id', agentId);

        // Delete agent
        await _supabase.from('agents').delete().eq('id', agentId);
      }
    }
  }

  static double _parseDecimal(String? value) {
    if (value == null || value.trim().isEmpty) return 0.0;
    // Remove commas and other formatting
    final cleaned = value.replaceAll(RegExp(r'[^\d.]'), '');
    return double.tryParse(cleaned) ?? 0.0;
  }

  static String _normalizeUniqueName(String value) {
    return value.trim().toLowerCase();
  }

  static int? _parseInt(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final cleaned = value.replaceAll(RegExp(r'[^\d]'), '');
    return int.tryParse(cleaned);
  }

  static bool _looksLikeUuid(String value) {
    final uuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    );
    return uuidPattern.hasMatch(value.trim());
  }

  static String? _parseDate(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    // Try to parse DD/MM/YYYY format (most common in the app)
    final ddmmyyyyPattern = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$');
    final match = ddmmyyyyPattern.firstMatch(trimmed);
    if (match != null) {
      final day = int.tryParse(match.group(1) ?? '');
      final month = int.tryParse(match.group(2) ?? '');
      final year = int.tryParse(match.group(3) ?? '');

      if (day != null && month != null && year != null) {
        // Validate date ranges
        if (month >= 1 &&
            month <= 12 &&
            day >= 1 &&
            day <= 31 &&
            year >= 1000 &&
            year <= 9999) {
          // Convert to ISO format (YYYY-MM-DD)
          return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
        }
      }
    }

    // Try to parse YYYY-MM-DD format (ISO format - already correct)
    final isoPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (isoPattern.hasMatch(trimmed)) {
      return trimmed;
    }

    // If format is not recognized, return null to avoid database errors
    _log('Warning: Could not parse date format: $trimmed');
    return null;
  }

  // Map any UI earning type string to one of the allowed DB values.
  // Allowed values per schema: Per Plot, Per Square Foot, Lump Sum.
  // Note: We distinguish between "Profit Per Plot" and "Selling Price Per Plot"
  // by checking for "profit" vs "selling price" keywords.
  static String? _mapEarningType(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return null;

    final lower = cleaned.toLowerCase();

    // Check for "selling price per plot" first (more specific)
    if (lower.contains('selling price') && lower.contains('plot')) {
      return 'Selling Price Per Plot';
    }

    // Check for "profit per plot" or "% of profit on each sold plot"
    if (lower.contains('profit') &&
        (lower.contains('plot') || lower.contains('sold'))) {
      return 'Profit Per Plot';
    }

    // Generic "per plot" (fallback)
    if (lower.contains('per plot')) {
      return 'Per Plot';
    }

    if (lower.contains('square foot') ||
        lower.contains('sqft') ||
        lower.contains('sq ft')) {
      return 'Per Square Foot';
    }

    if (lower.contains('total project profit') ||
        lower.contains('lump') ||
        lower.contains('project profit')) {
      return 'Lump Sum';
    }

    // If we don't recognize it, return null to avoid check constraint violations.
    _log(
        'Warning: Unrecognized earning type "$cleaned", storing as null to satisfy DB constraint');
    return null;
  }

  static Map<String, dynamic> _buildLocalPendingProjectData(
    Map<String, dynamic> pendingEntry,
  ) {
    final projectName = (pendingEntry['project_name'] ?? '').toString();
    final projectStatus =
        (pendingEntry['project_status'] ?? 'Active').toString();
    final areaUnit = AreaUnitUtils.canonicalizeAreaUnit(
      pendingEntry['area_unit']?.toString(),
    );
    return <String, dynamic>{
      'projectName': projectName,
      'projectStatus': projectStatus,
      'projectAreaUnit': areaUnit,
      'projectAddress': (pendingEntry['project_address'] ?? '').toString(),
      'googleMapsLink': (pendingEntry['google_maps_link'] ?? '').toString(),
      'totalArea': '0.00',
      'sellingArea': '0.00',
      'estimatedDevelopmentCost': '0.00',
      'nonSellableArea': '0.00',
      'allInCost': '0.00',
      'totalExpenses': '0.00',
      'totalLayouts': 0,
      'totalPlots': 0,
      'soldPlots': 0,
      'availablePlots': 0,
      'totalSalesValue': '0.00',
      'avgSalesPrice': '0.00',
      'grossProfit': '0.00',
      'netProfit': '0.00',
      'profitMargin': '0.00',
      'roi': '0.00',
      'totalPMCompensation': '0.00',
      'totalAgentCompensation': '0.00',
      'totalCompensation': '0.00',
      'partners': <Map<String, dynamic>>[],
      'expenses': <Map<String, dynamic>>[],
      'nonSellableAreas': <Map<String, dynamic>>[],
      'amenityAreas': <Map<String, dynamic>>[],
      'plots': <Map<String, dynamic>>[],
      'layouts': <Map<String, dynamic>>[],
      'project_managers': <Map<String, dynamic>>[],
      'agents': <Map<String, dynamic>>[],
      'plot_partners': <Map<String, dynamic>>[],
    };
  }

  /// Delete a project and all its associated data
  static Future<void> deleteProject(String projectId) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      // Delete the project - cascade delete should handle related records
      // (non_sellable_areas, partners, expenses, layouts, project_managers, agents, etc.)
      await _supabase
          .from('projects')
          .delete()
          .eq('id', projectId)
          .eq('user_id', userId);

      invalidateProjectCache(projectId);
      _log(
          'ProjectStorageService.deleteProject: Successfully deleted project $projectId');
    } catch (e) {
      _log('ProjectStorageService.deleteProject: Error deleting project: $e');
      rethrow;
    }
  }

  static void invalidateProjectCache(String projectId) {
    _projectDataCache.remove(projectId);
  }

  static void invalidateAllProjectCache() {
    _projectDataCache.clear();
  }

  static Map<String, dynamic> _deepCopyMap(Map<String, dynamic> source) {
    return source.map(
      (key, value) => MapEntry(key, _deepCopyDynamic(value)),
    );
  }

  static dynamic _deepCopyDynamic(dynamic value) {
    if (value is Map) {
      return value.map(
        (key, nestedValue) => MapEntry(
          key,
          _deepCopyDynamic(nestedValue),
        ),
      );
    }
    if (value is List) {
      return value.map(_deepCopyDynamic).toList();
    }
    return value;
  }
}
