import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LayoutStorageService {
  static const String _layoutsKey = 'project_layouts_data';
  static const String _projectNameKey = 'current_project_name';
  static const String _projectAddressKeyPrefix = 'project_address_';
  static const String _projectMapsLinkKeyPrefix = 'project_maps_link_';
  static const String _agentsKey = 'project_agents_data';

  static String _layoutsStorageKeyForProject(String? projectKey) {
    final key = projectKey?.trim() ?? '';
    if (key.isEmpty) return _layoutsKey;
    return '${_layoutsKey}_$key';
  }

  static String _normalizedLookupValue(dynamic value) {
    if (value == null) return '';
    final text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return '';
    return text.toLowerCase();
  }

  static String _firstNonEmptyText(Iterable<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty && text.toLowerCase() != 'null') {
        return text;
      }
    }
    return '';
  }

  static List<Map<String, dynamic>> _coerceLayouts(dynamic rawLayouts) {
    if (rawLayouts is! List) return const <Map<String, dynamic>>[];
    return rawLayouts
        .whereType<Map>()
        .map((layout) => Map<String, dynamic>.from(layout))
        .toList(growable: false);
  }

  static void _preserveTextFieldIfMissing(
    Map<String, dynamic> target,
    Map<String, dynamic>? existing, {
    required String targetKey,
    required List<String> sourceKeys,
  }) {
    if (existing == null) return;
    final currentValue = _firstNonEmptyText(
        [target[targetKey], ...sourceKeys.map((k) => target[k])]);
    if (currentValue.isNotEmpty) return;
    final existingValue =
        _firstNonEmptyText(sourceKeys.map((key) => existing[key]));
    if (existingValue.isNotEmpty) {
      target[targetKey] = existingValue;
    }
  }

  static String _sanitizeAgentName(
    String agentName, {
    required Set<String> validAgents,
    required bool enforceValidAgents,
  }) {
    if (agentName.isEmpty) return '';
    if (_normalizedLookupValue(agentName) == 'direct sale') {
      return agentName;
    }
    if (!enforceValidAgents) return agentName;
    return validAgents.contains(_normalizedLookupValue(agentName))
        ? agentName
        : '';
  }

  static List<Map<String, dynamic>> mergeLayoutsPreservingPlotMetadata({
    required List<Map<String, dynamic>> incomingLayouts,
    required List<Map<String, dynamic>> existingLayouts,
    Iterable<String>? validAgents,
  }) {
    final normalizedValidAgents = validAgents
            ?.map(_normalizedLookupValue)
            .where((name) => name.isNotEmpty)
            .toSet() ??
        <String>{};
    final enforceValidAgents = validAgents != null;

    final existingLayoutsById = <String, Map<String, dynamic>>{};
    final existingLayoutsByName = <String, Map<String, dynamic>>{};
    for (final rawLayout in existingLayouts) {
      final layout = Map<String, dynamic>.from(rawLayout);
      final layoutId = _firstNonEmptyText([layout['id']]);
      final layoutName = _normalizedLookupValue(layout['name']);
      if (layoutId.isNotEmpty) {
        existingLayoutsById[layoutId] = layout;
      }
      if (layoutName.isNotEmpty) {
        existingLayoutsByName[layoutName] = layout;
      }
    }

    return incomingLayouts.map((rawLayout) {
      final layout = Map<String, dynamic>.from(rawLayout);
      final layoutId = _firstNonEmptyText([layout['id']]);
      final layoutName = _normalizedLookupValue(layout['name']);
      final existingLayout =
          (layoutId.isNotEmpty ? existingLayoutsById[layoutId] : null) ??
              existingLayoutsByName[layoutName];

      final existingPlotsById = <String, Map<String, dynamic>>{};
      final existingPlotsByNumber = <String, Map<String, dynamic>>{};
      final existingPlotsRaw =
          existingLayout?['plots'] as List<dynamic>? ?? const [];
      for (final rawPlot in _coerceLayouts(existingPlotsRaw)) {
        final plot = Map<String, dynamic>.from(rawPlot);
        final plotId = _firstNonEmptyText([plot['id']]);
        final plotNumber = _normalizedLookupValue(plot['plotNumber']);
        if (plotId.isNotEmpty) {
          existingPlotsById[plotId] = plot;
        }
        if (plotNumber.isNotEmpty) {
          existingPlotsByNumber[plotNumber] = plot;
        }
      }

      final incomingPlotsRaw = layout['plots'] as List<dynamic>? ?? const [];
      final mergedPlots = incomingPlotsRaw.map((rawPlot) {
        final plot = rawPlot is Map
            ? Map<String, dynamic>.from(rawPlot)
            : <String, dynamic>{};
        final plotId = _firstNonEmptyText([plot['id']]);
        final plotNumber = _normalizedLookupValue(plot['plotNumber']);
        final existingPlot =
            (plotId.isNotEmpty ? existingPlotsById[plotId] : null) ??
                existingPlotsByNumber[plotNumber];

        if (existingPlot != null) {
          final incomingStatus = _normalizedLookupValue(plot['status']);
          final existingStatus = _normalizedLookupValue(existingPlot['status']);
          if ((incomingStatus.isEmpty || incomingStatus == 'available') &&
              existingStatus.isNotEmpty &&
              existingStatus != 'available') {
            plot['status'] = existingPlot['status'];
          }

          if (_firstNonEmptyText([plot['id']]).isEmpty &&
              _firstNonEmptyText([existingPlot['id']]).isNotEmpty) {
            plot['id'] = existingPlot['id'];
          }

          _preserveTextFieldIfMissing(
            plot,
            existingPlot,
            targetKey: 'salePrice',
            sourceKeys: const ['salePrice', 'sale_price'],
          );
          _preserveTextFieldIfMissing(
            plot,
            existingPlot,
            targetKey: 'buyerName',
            sourceKeys: const ['buyerName', 'buyer_name'],
          );
          _preserveTextFieldIfMissing(
            plot,
            existingPlot,
            targetKey: 'buyerContactNumber',
            sourceKeys: const [
              'buyerContactNumber',
              'buyer_contact_number',
              'buyer_mobile_number'
            ],
          );
          _preserveTextFieldIfMissing(
            plot,
            existingPlot,
            targetKey: 'saleDate',
            sourceKeys: const ['saleDate', 'sale_date'],
          );

          final incomingPayments =
              plot['payments'] as List<dynamic>? ?? const [];
          final existingPayments =
              existingPlot['payments'] as List<dynamic>? ?? const [];
          if (incomingPayments.isEmpty && existingPayments.isNotEmpty) {
            plot['payments'] = List<dynamic>.from(existingPayments);
          }
        }

        final resolvedAgent = _sanitizeAgentName(
          _firstNonEmptyText([
            plot['agent'],
            plot['agent_name'],
            plot['agentName'],
            if (existingPlot != null) ...[
              existingPlot['agent'],
              existingPlot['agent_name'],
              existingPlot['agentName'],
            ],
          ]),
          validAgents: normalizedValidAgents,
          enforceValidAgents: enforceValidAgents,
        );
        plot['agent'] = resolvedAgent;

        return plot;
      }).toList(growable: false);

      layout['plots'] = mergedPlots;
      return layout;
    }).toList(growable: false);
  }

  /// Save layout data to local storage (from project details page with controllers)
  static Future<void> saveLayoutsData(
    List<Map<String, dynamic>> layouts,
    Map<int, TextEditingController> layoutNameControllers,
    Map<String, TextEditingController> plotNumberControllers,
    Map<String, TextEditingController> plotAreaControllers,
    Map<String, TextEditingController> plotPurchaseRateControllers, {
    Map<String, List<String>>? plotPartners,
    Iterable<String>? validAgents,
    String? projectKey,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scopedKey = _layoutsStorageKeyForProject(projectKey);
      final existingLayoutsJson = prefs.getString(scopedKey);
      final existingLayouts =
          existingLayoutsJson == null || existingLayoutsJson.isEmpty
              ? const <Map<String, dynamic>>[]
              : _coerceLayouts(jsonDecode(existingLayoutsJson));

      // Extract actual values from controllers and build the data structure
      final layoutsData = <Map<String, dynamic>>[];

      for (int layoutIndex = 0; layoutIndex < layouts.length; layoutIndex++) {
        final layout = layouts[layoutIndex];
        final layoutNameController = layoutNameControllers[layoutIndex];
        final layoutName = layoutNameController?.text ??
            layout['name'] ??
            'Layout ${layoutIndex + 1}';

        final plots = layout['plots'] as List<dynamic>? ?? [];
        final plotsData = <Map<String, dynamic>>[];

        for (int plotIndex = 0; plotIndex < plots.length; plotIndex++) {
          final key = '${layoutIndex}_$plotIndex';
          final plotNumberController = plotNumberControllers[key];
          final plotAreaController = plotAreaControllers[key];
          final plotPurchaseRateController = plotPurchaseRateControllers[key];
          final plot = plots[plotIndex] is Map<String, dynamic>
              ? plots[plotIndex] as Map<String, dynamic>
              : <String, dynamic>{};

          plotsData.add({
            'id': plot['id'],
            'plotNumber': (plotNumberController?.text ??
                (plot['plotNumber'] ?? '').toString()),
            'area': (plotAreaController?.text ??
                (plot['area'] ?? '0.00').toString()),
            'purchaseRate': (plotPurchaseRateController?.text ??
                (plot['purchaseRate'] ?? '0.00').toString()),
            'totalPlotCost': plot['totalPlotCost'] ?? '0.00',
            'status': plot['status'] ?? 'available',
            'salePrice': plot['salePrice'],
            'buyerName': plot['buyerName'],
            'buyerContactNumber': (plot['buyerContactNumber'] ??
                    plot['buyer_contact_number'] ??
                    plot['buyer_mobile_number'] ??
                    '')
                .toString(),
            'agent': plot['agent'],
            'saleDate': plot['saleDate'],
            'payments': plot['payments'] ?? [],
            'partners': plotPartners?[key] ?? [],
          });
        }

        layoutsData.add({
          'id': layout['id'],
          'name': layoutName,
          'layoutImageName': layout['layoutImageName'],
          'layoutImagePath': layout['layoutImagePath'],
          'layoutImageDocId': layout['layoutImageDocId'],
          'layoutImageExtension': layout['layoutImageExtension'],
          'plots': plotsData,
        });
      }

      final mergedLayoutsData = mergeLayoutsPreservingPlotMetadata(
        incomingLayouts: layoutsData,
        existingLayouts: existingLayouts,
        validAgents: validAgents,
      );

      // Convert to JSON string and save
      final jsonString = jsonEncode(mergedLayoutsData);
      await prefs.setString(scopedKey, jsonString);
    } catch (e) {
      print('Error saving layouts data: $e');
    }
  }

  /// Load layout data from local storage
  static Future<List<Map<String, dynamic>>> loadLayoutsData({
    String? projectKey,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? jsonString;
      if (projectKey != null && projectKey.trim().isNotEmpty) {
        final scopedKey = _layoutsStorageKeyForProject(projectKey);
        jsonString = prefs.getString(scopedKey);
      } else {
        jsonString = prefs.getString(_layoutsKey);
      }

      if (jsonString == null || jsonString.isEmpty) {
        return [];
      }

      final decoded = jsonDecode(jsonString) as List<dynamic>;
      return decoded.map((item) => item as Map<String, dynamic>).toList();
    } catch (e) {
      print('Error loading layouts data: $e');
      return [];
    }
  }

  /// Save current project name
  static Future<void> saveProjectName(String projectName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_projectNameKey, projectName);
    } catch (e) {
      print('Error saving project name: $e');
    }
  }

  /// Load current project name
  static Future<String?> loadProjectName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_projectNameKey);
    } catch (e) {
      print('Error loading project name: $e');
      return null;
    }
  }

  /// Save project about details (address and maps link)
  static Future<void> saveProjectAbout({
    required String projectKey,
    required String projectAddress,
    required String googleMapsLink,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          '${_projectAddressKeyPrefix}$projectKey', projectAddress);
      await prefs.setString(
          '${_projectMapsLinkKeyPrefix}$projectKey', googleMapsLink);
    } catch (e) {
      print('Error saving project about details: $e');
    }
  }

  /// Load project about details (address and maps link)
  static Future<Map<String, String>> loadProjectAbout({
    required String projectKey,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final address =
          prefs.getString('${_projectAddressKeyPrefix}$projectKey') ?? '';
      final mapsLink =
          prefs.getString('${_projectMapsLinkKeyPrefix}$projectKey') ?? '';
      return {
        'address': address,
        'mapsLink': mapsLink,
      };
    } catch (e) {
      print('Error loading project about details: $e');
      return {
        'address': '',
        'mapsLink': '',
      };
    }
  }

  /// Save layout data directly (from plot status page with status info)
  static Future<void> saveLayoutsDataDirect(
    List<Map<String, dynamic>> layouts, {
    String? projectKey,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(layouts);
      await prefs.setString(
        _layoutsStorageKeyForProject(projectKey),
        jsonString,
      );
    } catch (e) {
      print('Error saving layouts data directly: $e');
    }
  }

  /// Clear all saved layout data
  static Future<void> clearLayoutsData({String? projectKey}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scopedKey = _layoutsStorageKeyForProject(projectKey);
      await prefs.remove(scopedKey);
      // Also clear legacy global key when clearing without an explicit project key.
      if (projectKey == null || projectKey.trim().isEmpty) {
        await prefs.remove(_layoutsKey);
      }
    } catch (e) {
      print('Error clearing layouts data: $e');
    }
  }

  /// Save agents data to local storage
  static Future<void> saveAgentsData(List<Map<String, dynamic>> agents) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Filter out empty agents and extract only name
      final agentsToSave = agents
          .where((agent) {
            final name = agent['name']?.toString().trim() ?? '';
            return name.isNotEmpty;
          })
          .map((agent) => {
                'name': agent['name']?.toString().trim() ?? '',
              })
          .toList();

      final jsonString = jsonEncode(agentsToSave);
      await prefs.setString(_agentsKey, jsonString);
    } catch (e) {
      print('Error saving agents data: $e');
    }
  }

  /// Load agents data from local storage
  static Future<List<Map<String, dynamic>>> loadAgentsData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_agentsKey);

      if (jsonString == null || jsonString.isEmpty) {
        return [];
      }

      final decoded = jsonDecode(jsonString) as List<dynamic>;
      return decoded.map((item) => item as Map<String, dynamic>).toList();
    } catch (e) {
      print('Error loading agents data: $e');
      return [];
    }
  }
}
