import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/area_unit_utils.dart';

class OfflineProjectSyncService {
  static const String _pendingCreateQueueKey =
      'offline_project_create_queue_v1';
  static const Duration _retryInterval = Duration(seconds: 8);

  static final Random _random = Random.secure();
  static final List<Map<String, dynamic>> _pendingCreateQueue =
      <Map<String, dynamic>>[];
  static bool _queueLoaded = false;
  static bool _isFlushing = false;
  static Timer? _retryTimer;

  static String _hex(int length) {
    const chars = '0123456789abcdef';
    final out = StringBuffer();
    for (int i = 0; i < length; i++) {
      out.write(chars[_random.nextInt(chars.length)]);
    }
    return out.toString();
  }

  static String generateClientProjectId() {
    final version = '4${_hex(3)}';
    const variants = <String>['8', '9', 'a', 'b'];
    final variant = '${variants[_random.nextInt(variants.length)]}${_hex(3)}';
    return '${_hex(8)}-${_hex(4)}-$version-$variant-${_hex(12)}';
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
      'timeout',
      'timed out',
      'status code: 0',
      'statuscode: null',
      'temporary failure in name resolution',
      'no address associated with hostname',
    ];
    return markers.any(msg.contains);
  }

  static bool _isDuplicateProjectInsertError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('duplicate key value violates unique constraint') &&
        (msg.contains('projects_pkey') || msg.contains('projects_user_id_'));
  }

  static Future<void> _ensureQueueLoaded() async {
    if (_queueLoaded) return;
    _queueLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingCreateQueueKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _pendingCreateQueue
        ..clear()
        ..addAll(
          decoded.whereType<Map>().map<Map<String, dynamic>>(
                (row) => Map<String, dynamic>.from(
                  row.cast<String, dynamic>(),
                ),
              ),
        );
    } catch (_) {
      _pendingCreateQueue.clear();
    }
  }

  static Future<void> _persistQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_pendingCreateQueue.isEmpty) {
        await prefs.remove(_pendingCreateQueueKey);
        return;
      }
      await prefs.setString(
        _pendingCreateQueueKey,
        jsonEncode(_pendingCreateQueue),
      );
    } catch (_) {
      // Best-effort persistence only.
    }
  }

  static Map<String, dynamic> _createQueueEntry({
    required String projectId,
    required String userId,
    required String ownerEmail,
    required String projectName,
    required String areaUnit,
  }) {
    final nowIso = DateTime.now().toIso8601String();
    return <String, dynamic>{
      'id': projectId,
      'user_id': userId,
      'owner_email': ownerEmail.isEmpty ? null : ownerEmail,
      'project_name': projectName,
      'area_unit': areaUnit,
      'project_status': 'Active',
      'project_address': '',
      'google_maps_link': '',
      'total_area': 0.0,
      'selling_area': 0.0,
      'estimated_development_cost': 0.0,
      'created_at': nowIso,
      'updated_at': nowIso,
      'queued_at_ms': DateTime.now().millisecondsSinceEpoch,
      'attempts': 0,
      'last_error': '',
    };
  }

  static Map<String, dynamic> _queueEntryToProjectListRow(
    Map<String, dynamic> entry,
  ) {
    return <String, dynamic>{
      'id': (entry['id'] ?? '').toString(),
      'user_id': (entry['user_id'] ?? '').toString(),
      'project_name': (entry['project_name'] ?? '').toString(),
      'created_at': (entry['created_at'] ?? '').toString(),
      'updated_at': (entry['updated_at'] ?? '').toString(),
      '_local_only': true,
      '_pending_sync': true,
    };
  }

  static Future<void> initialize({SupabaseClient? supabase}) async {
    await _ensureQueueLoaded();
    _retryTimer ??= Timer.periodic(
      _retryInterval,
      (_) => unawaited(flushPendingCreates(supabase: supabase)),
    );
    unawaited(flushPendingCreates(supabase: supabase));
  }

  static Future<Map<String, dynamic>> createProjectWithOfflineFallback({
    SupabaseClient? supabase,
    required String projectName,
    required String areaUnit,
  }) async {
    final client = supabase ?? Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    final userEmail = (client.auth.currentUser?.email ?? '').trim();
    if (userId == null || userId.trim().isEmpty) {
      throw Exception('You must be logged in to create a project');
    }

    await _ensureQueueLoaded();
    final canonicalAreaUnit = AreaUnitUtils.canonicalizeAreaUnit(areaUnit);
    final normalizedProjectName = projectName.trim();
    final projectId = generateClientProjectId();
    final queueEntry = _createQueueEntry(
      projectId: projectId,
      userId: userId,
      ownerEmail: userEmail,
      projectName: normalizedProjectName,
      areaUnit: canonicalAreaUnit,
    );

    try {
      await client.from('projects').insert(<String, dynamic>{
        'id': queueEntry['id'],
        'user_id': queueEntry['user_id'],
        'owner_email': queueEntry['owner_email'],
        'project_name': queueEntry['project_name'],
        'area_unit': queueEntry['area_unit'],
        'project_status': queueEntry['project_status'],
        'project_address': queueEntry['project_address'],
        'google_maps_link': queueEntry['google_maps_link'],
        'total_area': queueEntry['total_area'],
        'selling_area': queueEntry['selling_area'],
        'estimated_development_cost': queueEntry['estimated_development_cost'],
      });
      await removePendingProject(projectId: projectId, userId: userId);
      return <String, dynamic>{
        'projectId': projectId,
        'projectName': normalizedProjectName,
        'baseAreaUnit': canonicalAreaUnit,
        'savedLocally': false,
      };
    } catch (error) {
      if (!_isLikelyNetworkError(error)) {
        rethrow;
      }
      await _enqueuePendingCreate(queueEntry);
      return <String, dynamic>{
        'projectId': projectId,
        'projectName': normalizedProjectName,
        'baseAreaUnit': canonicalAreaUnit,
        'savedLocally': true,
      };
    }
  }

  static Future<void> _enqueuePendingCreate(
      Map<String, dynamic> queueEntry) async {
    await _ensureQueueLoaded();
    final projectId = (queueEntry['id'] ?? '').toString().trim();
    if (projectId.isEmpty) return;
    final existingIndex = _pendingCreateQueue
        .indexWhere((row) => (row['id'] ?? '').toString().trim() == projectId);
    if (existingIndex >= 0) {
      _pendingCreateQueue[existingIndex] = <String, dynamic>{...queueEntry};
    } else {
      _pendingCreateQueue.add(<String, dynamic>{...queueEntry});
    }
    await _persistQueue();
  }

  static Future<void> flushPendingCreates({
    SupabaseClient? supabase,
    String? userId,
  }) async {
    await _ensureQueueLoaded();
    if (_pendingCreateQueue.isEmpty) return;
    if (_isFlushing) return;

    final client = supabase ?? Supabase.instance.client;
    final currentUserId = (userId ?? client.auth.currentUser?.id ?? '').trim();
    if (currentUserId.isEmpty) return;

    _isFlushing = true;
    try {
      int index = 0;
      while (index < _pendingCreateQueue.length) {
        final entry = _pendingCreateQueue[index];
        final entryUserId = (entry['user_id'] ?? '').toString().trim();
        if (entryUserId.isEmpty || entryUserId != currentUserId) {
          index++;
          continue;
        }

        try {
          await client.from('projects').insert(<String, dynamic>{
            'id': entry['id'],
            'user_id': entry['user_id'],
            'owner_email': entry['owner_email'],
            'project_name': entry['project_name'],
            'area_unit': entry['area_unit'],
            'project_status': entry['project_status'],
            'project_address': entry['project_address'],
            'google_maps_link': entry['google_maps_link'],
            'total_area': entry['total_area'],
            'selling_area': entry['selling_area'],
            'estimated_development_cost': entry['estimated_development_cost'],
          });
          _pendingCreateQueue.removeAt(index);
          await _persistQueue();
          continue;
        } catch (error) {
          if (_isDuplicateProjectInsertError(error)) {
            _pendingCreateQueue.removeAt(index);
            await _persistQueue();
            continue;
          }
          entry['attempts'] = ((entry['attempts'] as num?)?.toInt() ?? 0) + 1;
          entry['last_error'] = error.toString();
          await _persistQueue();
          if (_isLikelyNetworkError(error)) {
            break;
          }
          index++;
        }
      }
    } finally {
      _isFlushing = false;
    }
  }

  static Future<List<Map<String, dynamic>>> getPendingProjectsForUser(
    String userId,
  ) async {
    await _ensureQueueLoaded();
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return <Map<String, dynamic>>[];
    return _pendingCreateQueue
        .where((entry) =>
            (entry['user_id'] ?? '').toString().trim() == normalizedUserId)
        .map<Map<String, dynamic>>(
            (entry) => _queueEntryToProjectListRow(entry))
        .toList(growable: false);
  }

  static Future<Map<String, dynamic>?> getPendingProjectEntryById(
    String projectId, {
    String? userId,
  }) async {
    await _ensureQueueLoaded();
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return null;
    final normalizedUserId = (userId ?? '').trim();
    for (final entry in _pendingCreateQueue) {
      final entryProjectId = (entry['id'] ?? '').toString().trim();
      if (entryProjectId != normalizedProjectId) continue;
      if (normalizedUserId.isNotEmpty) {
        final entryUserId = (entry['user_id'] ?? '').toString().trim();
        if (entryUserId != normalizedUserId) continue;
      }
      return <String, dynamic>{...entry};
    }
    return null;
  }

  static Future<List<Map<String, dynamic>>> mergeWithPendingProjectsForUser({
    required String userId,
    required List<Map<String, dynamic>> remoteProjects,
  }) async {
    final mergedById = <String, Map<String, dynamic>>{};
    for (final project in remoteProjects) {
      final id = (project['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      mergedById[id] = Map<String, dynamic>.from(project);
    }
    final pending = await getPendingProjectsForUser(userId);
    for (final project in pending) {
      final id = (project['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      mergedById.putIfAbsent(id, () => Map<String, dynamic>.from(project));
    }
    return mergedById.values.toList(growable: false);
  }

  static Future<bool> isPendingLocalProject({
    required String projectId,
    String? userId,
  }) async {
    await _ensureQueueLoaded();
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return false;
    final normalizedUserId = (userId ?? '').trim();
    return _pendingCreateQueue.any((entry) {
      final entryProjectId = (entry['id'] ?? '').toString().trim();
      if (entryProjectId != normalizedProjectId) return false;
      if (normalizedUserId.isEmpty) return true;
      return (entry['user_id'] ?? '').toString().trim() == normalizedUserId;
    });
  }

  static Future<void> removePendingProject({
    required String projectId,
    String? userId,
  }) async {
    await _ensureQueueLoaded();
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    final normalizedUserId = (userId ?? '').trim();
    _pendingCreateQueue.removeWhere((entry) {
      final entryProjectId = (entry['id'] ?? '').toString().trim();
      if (entryProjectId != normalizedProjectId) return false;
      if (normalizedUserId.isEmpty) return true;
      return (entry['user_id'] ?? '').toString().trim() == normalizedUserId;
    });
    await _persistQueue();
  }
}
