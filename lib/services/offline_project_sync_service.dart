import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/area_unit_utils.dart';

class OfflineProjectSyncService {
  static const String _pendingCreateQueueKey =
      'offline_project_create_queue_v1';
  static const String _anonymousOfflineOwnerUserId =
      '__offline_local_owner_v1__';
  static const String _lastKnownUserIdKey =
      'offline_project_last_known_user_id_v1';
  static const String _lastKnownUserEmailKey =
      'offline_project_last_known_user_email_v1';
  static const String _cloudSyncEnabledKeyPrefix =
      'project_cloud_sync_enabled_v1_';
  static const Duration _retryInterval = Duration(seconds: 8);
  static const Duration _remoteInsertTimeout = Duration(seconds: 6);
  static const Duration _identityResolveTimeout = Duration(milliseconds: 600);
  static const Duration _queueLoadTimeout = Duration(milliseconds: 600);
  static const Duration _queuePersistTimeout = Duration(milliseconds: 700);

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

  static bool _isDuplicateProjectInsertError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('duplicate key value violates unique constraint') &&
        (msg.contains('projects_pkey') || msg.contains('projects_user_id_'));
  }

  static bool _isAnonymousOfflineOwner(String userId) =>
      userId.trim() == _anonymousOfflineOwnerUserId;

  static Future<void> _insertProjectRowWithTimeout({
    required SupabaseClient client,
    required Map<String, dynamic> row,
  }) async {
    await client.from('projects').insert(row).timeout(
          _remoteInsertTimeout,
          onTimeout: () => throw TimeoutException(
            'projects insert timed out after '
            '${_remoteInsertTimeout.inSeconds}s',
          ),
        );
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

  static Future<void> _persistLastKnownIdentity({
    String? userId,
    String? userEmail,
  }) async {
    final normalizedUserId = (userId ?? '').trim();
    final normalizedUserEmail = (userEmail ?? '').trim();
    if (normalizedUserId.isEmpty && normalizedUserEmail.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (normalizedUserId.isNotEmpty) {
        await prefs.setString(_lastKnownUserIdKey, normalizedUserId);
      }
      if (normalizedUserEmail.isNotEmpty) {
        await prefs.setString(_lastKnownUserEmailKey, normalizedUserEmail);
      }
    } catch (_) {
      // Best-effort identity persistence only.
    }
  }

  static Future<String> _readLastKnownUserId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getString(_lastKnownUserIdKey) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  static Future<String> _readLastKnownUserEmail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getString(_lastKnownUserEmailKey) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  static Future<String?> resolveCurrentOrLastKnownUserId({
    SupabaseClient? supabase,
  }) async {
    final client = supabase ?? Supabase.instance.client;
    final sessionUser = client.auth.currentSession?.user;
    final currentUserId =
        (client.auth.currentUser?.id ?? sessionUser?.id ?? '').trim();
    final currentUserEmail =
        (client.auth.currentUser?.email ?? sessionUser?.email ?? '').trim();
    if (currentUserId.isNotEmpty) {
      await _persistLastKnownIdentity(
        userId: currentUserId,
        userEmail: currentUserEmail,
      );
      return currentUserId;
    }
    final lastKnownUserId = await _readLastKnownUserId();
    if (lastKnownUserId.isEmpty) return null;
    return lastKnownUserId;
  }

  static Future<String?> resolveCurrentOrLastKnownUserEmail({
    SupabaseClient? supabase,
  }) async {
    final client = supabase ?? Supabase.instance.client;
    final sessionUser = client.auth.currentSession?.user;
    final currentUserId =
        (client.auth.currentUser?.id ?? sessionUser?.id ?? '').trim();
    final currentUserEmail =
        (client.auth.currentUser?.email ?? sessionUser?.email ?? '').trim();
    if (currentUserEmail.isNotEmpty) {
      await _persistLastKnownIdentity(
        userId: currentUserId,
        userEmail: currentUserEmail,
      );
      return currentUserEmail;
    }
    final lastKnownUserEmail = await _readLastKnownUserEmail();
    if (lastKnownUserEmail.isEmpty) return null;
    return lastKnownUserEmail;
  }

  static String _cloudSyncEnabledPrefsKey(String projectId) {
    return '$_cloudSyncEnabledKeyPrefix${projectId.trim()}';
  }

  static Future<bool> isCloudSyncEnabledForProject(
    String projectId, {
    bool defaultValue = false,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return defaultValue;
    try {
      final prefs = await SharedPreferences.getInstance();
      final value =
          prefs.getBool(_cloudSyncEnabledPrefsKey(normalizedProjectId));
      return value ?? defaultValue;
    } catch (_) {
      return defaultValue;
    }
  }

  static Future<void> setCloudSyncEnabledForProject(
    String projectId,
    bool enabled,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
        _cloudSyncEnabledPrefsKey(normalizedProjectId),
        enabled,
      );
    } catch (_) {
      // Best-effort preference write.
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
    unawaited(resolveCurrentOrLastKnownUserId(supabase: supabase));
    unawaited(resolveCurrentOrLastKnownUserEmail(supabase: supabase));
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
    final sessionUser = client.auth.currentSession?.user;
    String resolvedUserId =
        (client.auth.currentUser?.id ?? sessionUser?.id ?? '').trim();
    String userEmail =
        (client.auth.currentUser?.email ?? sessionUser?.email ?? '').trim();
    if (resolvedUserId.isEmpty) {
      try {
        resolvedUserId =
            ((await resolveCurrentOrLastKnownUserId(supabase: client).timeout(
                      _identityResolveTimeout,
                      onTimeout: () => null,
                    )) ??
                    '')
                .trim();
      } catch (_) {
        resolvedUserId = '';
      }
    }
    final userId =
        resolvedUserId.isEmpty ? _anonymousOfflineOwnerUserId : resolvedUserId;
    if (userEmail.isEmpty) {
      try {
        userEmail = ((await resolveCurrentOrLastKnownUserEmail(
                  supabase: client,
                ).timeout(
                  _identityResolveTimeout,
                  onTimeout: () => null,
                )) ??
                '')
            .trim();
      } catch (_) {
        userEmail = '';
      }
    }
    try {
      await _ensureQueueLoaded().timeout(
        _queueLoadTimeout,
        onTimeout: () => null,
      );
    } catch (_) {
      // Continue via in-memory queue write if local storage is delayed.
    }
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

    // New projects are local-first and do not sync until explicitly enabled.
    await setCloudSyncEnabledForProject(projectId, false);

    // Queue-first creation keeps UX responsive even when network/auth is flaky.
    _upsertPendingCreateInMemory(<String, dynamic>{
      ...queueEntry,
      'attempts': 0,
      'last_error': resolvedUserId.isEmpty
          ? 'queued_offline_without_identity'
          : 'queued_offline_pending_sync',
    });
    try {
      await _persistQueue().timeout(
        _queuePersistTimeout,
        onTimeout: () => null,
      );
    } catch (_) {
      // Best-effort persistence; in-memory queue is already updated.
    }

    unawaited(
      flushPendingCreates(
        supabase: client,
        userId: resolvedUserId.isEmpty ? null : resolvedUserId,
      ),
    );

    return <String, dynamic>{
      'projectId': projectId,
      'projectName': normalizedProjectName,
      'baseAreaUnit': canonicalAreaUnit,
      'savedLocally': true,
    };
  }

  static void _upsertPendingCreateInMemory(Map<String, dynamic> queueEntry) {
    final projectId = (queueEntry['id'] ?? '').toString().trim();
    if (projectId.isEmpty) return;
    final existingIndex = _pendingCreateQueue
        .indexWhere((row) => (row['id'] ?? '').toString().trim() == projectId);
    if (existingIndex >= 0) {
      _pendingCreateQueue[existingIndex] = <String, dynamic>{...queueEntry};
    } else {
      _pendingCreateQueue.add(<String, dynamic>{...queueEntry});
    }
  }

  static Future<void> flushPendingCreates({
    SupabaseClient? supabase,
    String? userId,
    String? projectId,
    bool ignoreCloudSyncGate = false,
  }) async {
    await _ensureQueueLoaded();
    if (_pendingCreateQueue.isEmpty) return;
    if (_isFlushing) return;

    final client = supabase ?? Supabase.instance.client;
    final currentUserId = (userId ?? '').trim().isNotEmpty
        ? (userId ?? '').trim()
        : (await resolveCurrentOrLastKnownUserId(supabase: client) ?? '')
            .trim();
    if (currentUserId.isEmpty) return;
    final currentUserEmail =
        (await resolveCurrentOrLastKnownUserEmail(supabase: client) ?? '')
            .trim();

    _isFlushing = true;
    try {
      int index = 0;
      final normalizedProjectId = (projectId ?? '').trim();
      while (index < _pendingCreateQueue.length) {
        final entry = _pendingCreateQueue[index];
        final projectId = (entry['id'] ?? '').toString().trim();
        if (projectId.isEmpty) {
          index++;
          continue;
        }
        if (normalizedProjectId.isNotEmpty &&
            projectId != normalizedProjectId) {
          index++;
          continue;
        }
        if (!ignoreCloudSyncGate) {
          final cloudSyncEnabled = await isCloudSyncEnabledForProject(projectId,
              defaultValue: false);
          if (!cloudSyncEnabled) {
            index++;
            continue;
          }
        }
        final entryUserId = (entry['user_id'] ?? '').toString().trim();
        final isAnonymousEntry = _isAnonymousOfflineOwner(entryUserId);
        if (entryUserId.isEmpty ||
            (!isAnonymousEntry && entryUserId != currentUserId)) {
          index++;
          continue;
        }
        final entryOwnerEmail = (entry['owner_email'] ?? '').toString().trim();
        final ownerEmailToInsert = entryOwnerEmail.isNotEmpty
            ? entryOwnerEmail
            : (currentUserEmail.isEmpty ? null : currentUserEmail);

        try {
          await _insertProjectRowWithTimeout(
            client: client,
            row: <String, dynamic>{
              'id': entry['id'],
              'user_id': currentUserId,
              'owner_email': ownerEmailToInsert,
              'project_name': entry['project_name'],
              'area_unit': entry['area_unit'],
              'project_status': entry['project_status'],
              'project_address': entry['project_address'],
              'google_maps_link': entry['google_maps_link'],
              'total_area': entry['total_area'],
              'selling_area': entry['selling_area'],
              'estimated_development_cost': entry['estimated_development_cost'],
            },
          );
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
    return _pendingCreateQueue
        .where((entry) {
          final entryUserId = (entry['user_id'] ?? '').toString().trim();
          if (normalizedUserId.isEmpty) {
            return _isAnonymousOfflineOwner(entryUserId);
          }
          return entryUserId == normalizedUserId ||
              _isAnonymousOfflineOwner(entryUserId);
        })
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
        if (entryUserId != normalizedUserId &&
            !_isAnonymousOfflineOwner(entryUserId)) {
          continue;
        }
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
      final entryUserId = (entry['user_id'] ?? '').toString().trim();
      return entryUserId == normalizedUserId ||
          _isAnonymousOfflineOwner(entryUserId);
    });
  }

  static Future<int> pendingCreateCount({
    String? projectId,
    String? userId,
  }) async {
    await _ensureQueueLoaded();
    final normalizedProjectId = (projectId ?? '').trim();
    final normalizedUserId = (userId ?? '').trim();
    var count = 0;
    for (final entry in _pendingCreateQueue) {
      final entryProjectId = (entry['id'] ?? '').toString().trim();
      if (normalizedProjectId.isNotEmpty &&
          entryProjectId != normalizedProjectId) {
        continue;
      }
      if (normalizedUserId.isNotEmpty) {
        final entryUserId = (entry['user_id'] ?? '').toString().trim();
        if (entryUserId != normalizedUserId &&
            !_isAnonymousOfflineOwner(entryUserId)) {
          continue;
        }
      }
      count++;
    }
    return count;
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
      final entryUserId = (entry['user_id'] ?? '').toString().trim();
      return entryUserId == normalizedUserId ||
          _isAnonymousOfflineOwner(entryUserId);
    });
    await _persistQueue();
  }
}
