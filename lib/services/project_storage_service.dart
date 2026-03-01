import 'package:supabase_flutter/supabase_flutter.dart';

class ProjectStorageService {
  static final SupabaseClient _supabase = Supabase.instance.client;
  static bool? _hasBuyerContactNumberColumn;

  static Future<bool> _supportsBuyerContactNumberColumn() async {
    // Cache only successful detection. If previously false (e.g. column added
    // later), re-check so app can start saving without restart.
    if (_hasBuyerContactNumberColumn == true) {
      return true;
    }
    try {
      await _supabase.from('plots').select('buyer_contact_number').limit(1);
      _hasBuyerContactNumberColumn = true;
    } catch (_) {
      _hasBuyerContactNumberColumn = false;
    }
    return _hasBuyerContactNumberColumn!;
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

  /// Fetch complete project data from Supabase by projectId
  static Future<Map<String, dynamic>?> fetchProjectDataById(
      String projectId) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      // Fetch main project info
      final project = await _supabase
          .from('projects')
          .select()
          .eq('id', projectId)
          .eq('user_id', userId)
          .maybeSingle();
      if (project == null) return null;

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

      final layouts =
          await _supabase.from('layouts').select().eq('project_id', projectId);

      final projectManagers = await _supabase
          .from('project_managers')
          .select()
          .eq('project_id', projectId);

      final agents =
          await _supabase.from('agents').select().eq('project_id', projectId);

      // Fetch all plots for calculations
      final plots = <Map<String, dynamic>>[];
      final plotIds = <String>[];
      for (var layout in layouts) {
        final layoutPlots = await _supabase
            .from('plots')
            .select()
            .eq('layout_id', layout['id'] as String);
        plots.addAll(layoutPlots);
        for (var p in layoutPlots) {
          if (p['id'] != null) plotIds.add(p['id'].toString());
        }
      }

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

      // Calculate profitability metrics using plot-based gross profit (same as dashboard)
      // Gross Profit = For each SOLD plot: (sale_price × area) - (area × all_in_cost)
      final grossProfit =
          plots.where((p) => p['status'] == 'sold').fold<double>(
        0.0,
        (sum, plot) {
          final salePrice = ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
          final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
          final allInCostPerSqft =
              ((plot['all_in_cost_per_sqft'] as num?)?.toDouble() ?? 0.0);
          final plotProfit = (salePrice * area) - (area * allInCostPerSqft);
          return sum + plotProfit;
        },
      );
      final netProfit = grossProfit - totalCompensation;
      final profitMargin =
          totalSalesValue > 0 ? ((netProfit / totalSalesValue) * 100) : 0.0;
      final roi = estimatedCost > 0 ? ((netProfit / estimatedCost) * 100) : 0.0;

      // Compose result in the same structure as used in the report
      return {
        'projectName': project['project_name'],
        'projectStatus': project['project_status'],
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
        'plots': plots,
        'layouts': layouts,
        'project_managers': projectManagers,
        'agents': agents,
        'plot_partners': plotPartners,
      };
    } catch (e) {
      print('Error fetching project data: $e');
      return null;
    }
  }

  /// Save complete project data to Supabase
  static Future<void> saveProjectData({
    required String projectId,
    String? projectName,
    String? projectStatus,
    String? projectAddress,
    String? googleMapsLink,
    String? totalArea,
    String? sellingArea,
    String? estimatedDevelopmentCost,
    List<Map<String, String>>? nonSellableAreas,
    List<Map<String, dynamic>>? partners,
    List<Map<String, dynamic>>? expenses,
    List<Map<String, dynamic>>? layouts,
    List<Map<String, dynamic>>? projectManagers,
    List<Map<String, dynamic>>? agents,
  }) async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      // Get current project to check existing name
      final currentProject = await _supabase
          .from('projects')
          .select('project_name')
          .eq('id', projectId)
          .eq('user_id', userId)
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
        print(
            'ProjectStorageService.saveProjectData: Updating total_area: "$totalArea" -> $parsedTotalArea');
      }

      // Only update selling_area if explicitly provided
      if (sellingArea != null && sellingArea.trim().isNotEmpty) {
        final parsedSellingArea = _parseDecimal(sellingArea);
        updateData['selling_area'] = parsedSellingArea;
        print(
            'ProjectStorageService.saveProjectData: Updating selling_area: "$sellingArea" -> $parsedSellingArea');
      }

      // Only update estimated_development_cost if explicitly provided
      if (estimatedDevelopmentCost != null &&
          estimatedDevelopmentCost.trim().isNotEmpty) {
        final parsedEstimatedCost = _parseDecimal(estimatedDevelopmentCost);
        updateData['estimated_development_cost'] = parsedEstimatedCost;
        print(
            'ProjectStorageService.saveProjectData: Updating estimated_development_cost: "$estimatedDevelopmentCost" -> $parsedEstimatedCost');
      }

      // Update status/address/location when explicitly provided.
      // Unlike numeric fields, empty string is valid here (user can clear address/link).
      if (projectStatus != null) {
        updateData['project_status'] = projectStatus.trim();
      }
      if (projectAddress != null) {
        updateData['project_address'] = projectAddress.trim();
      }
      if (googleMapsLink != null) {
        updateData['google_maps_link'] = googleMapsLink.trim();
      }

      print(
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
              .eq('user_id', userId)
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
      print(
          'ProjectStorageService.saveProjectData: Updating project with data: $updateData');
      final updateResult = await _supabase
          .from('projects')
          .update(updateData)
          .eq('id', projectId)
          .eq('user_id', userId)
          .select();
      print(
          'ProjectStorageService.saveProjectData: Update result: $updateResult');

      final sectionErrors = <String>[];

      // Save expenses first so dashboard totals stay fresh even when
      // unrelated sections (e.g., partners/layouts) fail validation.
      if (expenses != null) {
        try {
          await _saveExpenses(projectId, expenses);
        } catch (e) {
          sectionErrors.add('expenses: $e');
        }
      }

      // Save non-sellable areas - only if explicitly provided.
      if (nonSellableAreas != null) {
        try {
          await _saveNonSellableAreas(projectId, nonSellableAreas);
        } catch (e) {
          sectionErrors.add('non_sellable_areas: $e');
        }
      }

      // Save partners - only if explicitly provided (prevents deletion when
      // saving from other pages). If partners is null, do not modify them.
      if (partners != null) {
        try {
          await _savePartners(projectId, partners);
        } catch (e) {
          sectionErrors.add('partners: $e');
        }
      }

      if (layouts != null) {
        try {
          await _saveLayoutsAndPlots(projectId, layouts);
        } catch (e) {
          sectionErrors.add('layouts: $e');
        }
      }

      if (projectManagers != null) {
        try {
          await _saveProjectManagers(projectId, projectManagers);
        } catch (e) {
          sectionErrors.add('project_managers: $e');
        }
      }

      if (agents != null) {
        try {
          await _saveAgents(projectId, agents);
        } catch (e) {
          sectionErrors.add('agents: $e');
        }
      }

      if (sectionErrors.isNotEmpty) {
        throw Exception(
            'Partial save failure for project $projectId -> ${sectionErrors.join(' | ')}');
      }
    } catch (e) {
      print('Error saving project data: $e');
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
    // Safer than delete-all + insert-all:
    // update existing rows by id, insert new rows, delete only rows explicitly removed.
    final existingExpenses = await _supabase
        .from('expenses')
        .select('id')
        .eq('project_id', projectId);
    final existingIds = existingExpenses
        .map((e) => (e['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    final retainedIds = <String>{};

    for (final expense in expenses) {
      final item = expense['item']?.toString().trim() ?? '';
      final category = expense['category']?.toString().trim() ?? '';
      if (item.isEmpty || category.isEmpty) {
        continue;
      }

      final payload = {
        'item': item,
        'amount': _parseDecimal(expense['amount']?.toString()),
        'category': category,
      };

      final expenseId = (expense['id'] ?? '').toString().trim();
      if (expenseId.isNotEmpty) {
        await _supabase
            .from('expenses')
            .update(payload)
            .eq('id', expenseId)
            .eq('project_id', projectId);
        retainedIds.add(expenseId);
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
        }
      }
    }

    final idsToDelete = existingIds.difference(retainedIds);
    for (final id in idsToDelete) {
      await _supabase.from('expenses').delete().eq('id', id);
    }
  }

  static Future<void> _saveLayoutsAndPlots(
    String projectId,
    List<Map<String, dynamic>> layouts,
  ) async {
    final errors = <String>[];
    final supportsBuyerContactNumber =
        await _supportsBuyerContactNumberColumn();

    // Get existing layouts for this project
    final existingLayouts = await _supabase
        .from('layouts')
        .select('id, name')
        .eq('project_id', projectId);

    final existingLayoutMap = <String, String>{};
    for (var layout in existingLayouts) {
      final name = (layout['name'] ?? '').toString().trim();
      if (name.isNotEmpty) {
        existingLayoutMap[name] = layout['id'];
      }
    }

    // Process each layout
    for (var layoutData in layouts) {
      final layoutName = (layoutData['name'] ?? '').toString().trim();
      if (layoutName.isEmpty) continue;

      String layoutId;
      if (existingLayoutMap.containsKey(layoutName)) {
        layoutId = existingLayoutMap[layoutName]!;
      } else {
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
              print(msg);
              errors.add(msg);
              continue; // Skip this layout
            }
          } else {
            rethrow;
          }
        }
      }

      // Get plots for this layout
      final plots = layoutData['plots'] as List<dynamic>? ?? [];

      final existingPlots = await _supabase
          .from('plots')
          .select('id, plot_number')
          .eq('layout_id', layoutId);
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
            print(
                'Saving plot: plotNumber=$plotNumber, purchaseRate=$purchaseRate, allInCostPerSqft=$allInCostPerSqft, totalPlotCost=$totalPlotCost');
          }

          // Debug payments data
          final paymentsData = plotData['payments'];
          print(
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

          if (supportsBuyerContactNumber &&
              plotData is Map &&
              plotData.containsKey('buyerContactNumber')) {
            final rawBuyerContact =
                (plotData['buyerContactNumber'] ?? '').toString().trim();
            plotDataToSave['buyer_contact_number'] =
                rawBuyerContact.isEmpty ? null : rawBuyerContact;
          }

          final incomingPlotId =
              (plotData is Map ? (plotData['id'] ?? '').toString().trim() : '');
          Map<String, dynamic> newPlot;
          if (incomingPlotId.isNotEmpty) {
            newPlot = await _supabase
                .from('plots')
                .update(plotDataToSave)
                .eq('id', incomingPlotId)
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
            print(
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
              print(
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
            print(
                'DEBUG ProjectStorageService: Skipping partner update for plot ${newPlot['plot_number']} (partners field not provided)');
          }
        } catch (e) {
          final msg = 'Error saving plot $plotNumber: $e';
          print(msg);
          errors.add(msg);
          layoutHadPlotSaveError = true;
          continue;
        }
      }

      // Delete plots only when this layout saved cleanly.
      // If any plot failed to save, skip deletion to prevent accidental data loss.
      if (!layoutHadPlotSaveError) {
        for (final existingPlot in existingPlots) {
          final existingPlotId = (existingPlot['id'] ?? '').toString();
          if (existingPlotId.isNotEmpty &&
              !retainedPlotIds.contains(existingPlotId)) {
            final existingPlotNumber =
                (existingPlot['plot_number'] ?? '').toString().trim();
            print(
                'Deleting plot removed from layout $layoutId: $existingPlotNumber');
            await _supabase.from('plots').delete().eq('id', existingPlotId);
          }
        }
      } else {
        final msg =
            '_saveLayoutsAndPlots: Skipping plot deletions for layout "$layoutName" due to save errors';
        print(msg);
        errors.add(msg);
      }
    }

    // Delete layouts that are no longer in the data
    final currentLayoutNames = layouts
        .map((l) => (l['name'] ?? '').toString().trim())
        .where((n) => n.isNotEmpty)
        .toSet();
    final layoutsToDelete = existingLayoutMap.entries
        .where((e) => !currentLayoutNames.contains(e.key))
        .map((e) => e.value)
        .toList();

    print('_saveLayoutsAndPlots: Current layout names: $currentLayoutNames');
    print('_saveLayoutsAndPlots: Existing layout map: $existingLayoutMap');
    print('_saveLayoutsAndPlots: Layouts to delete: ${layoutsToDelete.length}');

    if (layoutsToDelete.isNotEmpty) {
      for (var layoutId in layoutsToDelete) {
        print('Deleting layout: $layoutId');
        await _supabase.from('layouts').delete().eq('id', layoutId);
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
    print(
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
        print('_saveProjectManagers: Skipping duplicate manager with id=$id');
        continue;
      }
      if (id != null) {
        seenIds.add(id);
      }
      uniqueManagers.add(managerData);
    }

    print(
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
          print(
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
        print('_saveProjectManagers: Skipping manager with empty name');
        continue;
      }

      final compensationType = managerData['compensation']?.toString();
      final earningType = managerData['earningType']?.toString();

      print(
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

      print(
          '_saveProjectManagers: Mapped values: compensation_type="$finalCompensationType", earning_type="$finalEarningType"');

      String? managerId = managerData['id']?.toString();
      if (managerId == null || managerId.trim().isEmpty) {
        managerId = existingManagerIdByName[name.toLowerCase()];
        if (managerId != null) {
          print(
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
          print(
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
          print(
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
          print(
              '_saveProjectManagers: Warning: failed to save blocks for manager "$name" (id=$finalManagerId): $e');
        }
      } catch (e) {
        final errorMsg =
            '_saveProjectManagers: Error upserting manager "$name": $e';
        print(errorMsg);
        errors.add(errorMsg);
        // Continue processing remaining managers instead of stopping
        continue;
      }
    }

    // Log any errors that occurred
    if (errors.isNotEmpty) {
      print(
          '_saveProjectManagers: ${errors.length} error(s) occurred while saving managers:');
      for (var error in errors) {
        print('  - $error');
      }
      print(
          '_saveProjectManagers: Skipping deletion of existing managers due save errors to prevent data loss');
      throw Exception(
          '_saveProjectManagers failed with ${errors.length} error(s). First error: ${errors.first}');
    }

    print(
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
    print('_saveAgents: Saving ${agents.length} agents for project $projectId');

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
        print('_saveAgents: Skipping agent with empty name');
        continue;
      }

      final compensationType = agentData['compensation']?.toString();
      final earningType = agentData['earningType']?.toString();
      final percentage = agentData['percentage']?.toString();
      final fixedFee = agentData['fixedFee']?.toString();
      final monthlyFee = agentData['monthlyFee']?.toString();
      final months = agentData['months']?.toString();
      final perSqftFee = agentData['perSqftFee']?.toString();

      print(
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

      print(
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

      print('_saveAgents: Data to upsert: $dataToUpsert');

      // If ID exists, add it to update existing record.
      // If UI row has no id, match by name to avoid duplicate inserts.
      String? agentId = agentData['id']?.toString();
      if (agentId == null || agentId.trim().isEmpty) {
        agentId = existingAgentIdByName[name.toLowerCase()];
        if (agentId != null) {
          print(
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
        print('_saveAgents: Successfully upserted agent: $upsertedAgent');

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
          print(
              '_saveAgents: Warning: failed to save blocks for agent "$name" (id=$savedAgentId): $e');
        }
      } catch (e) {
        final errorMsg = '_saveAgents: Error upserting agent "$name": $e';
        print(errorMsg);
        errors.add(errorMsg);
        // Continue processing remaining agents instead of stopping
        continue;
      }
    }

    // Log any errors that occurred
    if (errors.isNotEmpty) {
      print(
          '_saveAgents: ${errors.length} error(s) occurred while saving agents:');
      for (var error in errors) {
        print('  - $error');
      }
      print(
          '_saveAgents: Skipping deletion of existing agents due save errors to prevent data loss');
      throw Exception(
          '_saveAgents failed with ${errors.length} error(s). First error: ${errors.first}');
    }

    print(
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
    print('Warning: Could not parse date format: $trimmed');
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
    print(
        'Warning: Unrecognized earning type "$cleaned", storing as null to satisfy DB constraint');
    return null;
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

      print(
          'ProjectStorageService.deleteProject: Successfully deleted project $projectId');
    } catch (e) {
      print('ProjectStorageService.deleteProject: Error deleting project: $e');
      rethrow;
    }
  }
}
