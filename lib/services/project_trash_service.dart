import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ProjectTrashService {
  ProjectTrashService._();

  static const String _hiddenProjectIdsKeyPrefix = 'project_hidden_ids_v1_';
  static const String _trashedProjectsKeyPrefix = 'project_trash_rows_v1_';

  static String _hiddenProjectIdsKey(String userId) =>
      '$_hiddenProjectIdsKeyPrefix${userId.trim()}';

  static String _trashedProjectsKey(String userId) =>
      '$_trashedProjectsKeyPrefix${userId.trim()}';

  static Future<Set<String>> hiddenProjectIdsForUser(String userId) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_hiddenProjectIdsKey(normalizedUserId));
      if (raw == null || raw.isEmpty) return <String>{};
      return raw.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<List<Map<String, dynamic>>> trashedProjectsForUser(
    String userId,
  ) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw =
          (prefs.getString(_trashedProjectsKey(normalizedUserId)) ?? '').trim();
      if (raw.isEmpty) return const <Map<String, dynamic>>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <Map<String, dynamic>>[];
      final out = <Map<String, dynamic>>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final row = Map<String, dynamic>.from(entry.cast<String, dynamic>());
        final id = (row['id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        out.add(row);
      }
      out.sort((a, b) {
        final aDeletedAt = (a['deleted_at_ms'] as num?)?.toInt() ?? 0;
        final bDeletedAt = (b['deleted_at_ms'] as num?)?.toInt() ?? 0;
        return bDeletedAt.compareTo(aDeletedAt);
      });
      return out;
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  static Future<List<Map<String, dynamic>>> filterOutHiddenProjects({
    required String userId,
    required List<Map<String, dynamic>> projects,
  }) async {
    final hiddenIds = await hiddenProjectIdsForUser(userId);
    if (hiddenIds.isEmpty) {
      return projects
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    }
    return projects
        .where(
            (row) => !hiddenIds.contains((row['id'] ?? '').toString().trim()))
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  static Future<void> moveToTrash({
    required String userId,
    required Map<String, dynamic> project,
  }) async {
    final normalizedUserId = userId.trim();
    final projectId = (project['id'] ?? '').toString().trim();
    if (normalizedUserId.isEmpty || projectId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final hiddenIds = await hiddenProjectIdsForUser(normalizedUserId);
      final nextHiddenIds = <String>{...hiddenIds, projectId};
      await prefs.setStringList(
        _hiddenProjectIdsKey(normalizedUserId),
        nextHiddenIds.toList(growable: false),
      );

      final currentTrash = await trashedProjectsForUser(normalizedUserId);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final snapshot = <String, dynamic>{
        'id': projectId,
        'project_name': (project['project_name'] ?? '').toString(),
        'created_at': (project['created_at'] ?? '').toString(),
        'updated_at': (project['updated_at'] ?? '').toString(),
        'deleted_at_ms': nowMs,
      };
      final nextTrash = <Map<String, dynamic>>[snapshot];
      for (final row in currentTrash) {
        final rowId = (row['id'] ?? '').toString().trim();
        if (rowId.isEmpty || rowId == projectId) continue;
        nextTrash.add(Map<String, dynamic>.from(row));
      }
      await prefs.setString(
        _trashedProjectsKey(normalizedUserId),
        jsonEncode(nextTrash),
      );
    } catch (_) {
      // Best-effort local trash state.
    }
  }

  static Future<void> restoreFromTrash({
    required String userId,
    required String projectId,
  }) async {
    final normalizedUserId = userId.trim();
    final normalizedProjectId = projectId.trim();
    if (normalizedUserId.isEmpty || normalizedProjectId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final hiddenIds = await hiddenProjectIdsForUser(normalizedUserId);
      final nextHiddenIds = hiddenIds
          .where((id) => id.trim() != normalizedProjectId)
          .toList(growable: false);
      if (nextHiddenIds.isEmpty) {
        await prefs.remove(_hiddenProjectIdsKey(normalizedUserId));
      } else {
        await prefs.setStringList(
          _hiddenProjectIdsKey(normalizedUserId),
          nextHiddenIds,
        );
      }

      final currentTrash = await trashedProjectsForUser(normalizedUserId);
      final nextTrash = currentTrash
          .where(
            (row) => (row['id'] ?? '').toString().trim() != normalizedProjectId,
          )
          .toList(growable: false);
      if (nextTrash.isEmpty) {
        await prefs.remove(_trashedProjectsKey(normalizedUserId));
      } else {
        await prefs.setString(
          _trashedProjectsKey(normalizedUserId),
          jsonEncode(nextTrash),
        );
      }
    } catch (_) {
      // Best-effort local trash state.
    }
  }
}
