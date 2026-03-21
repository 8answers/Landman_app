import 'package:supabase_flutter/supabase_flutter.dart';

class ProjectAccessService {
  ProjectAccessService._();

  static final SupabaseClient _supabase = Supabase.instance.client;
  static bool? _hasAccessControlTables;

  static String normalizeRole(String? rawRole) {
    final normalized = (rawRole ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'partner':
      case 'project_manager':
      case 'agent':
      case 'admin':
      case 'owner':
        return normalized;
      default:
        return 'partner';
    }
  }

  static int _roleSortOrder(String normalizedRole) {
    switch (normalizedRole) {
      case 'owner':
        return 0;
      case 'admin':
        return 1;
      case 'project_manager':
        return 2;
      case 'partner':
        return 3;
      case 'agent':
        return 4;
      case 'paused':
        return 5;
      default:
        return 99;
    }
  }

  static List<String> sortRolesForUi(Iterable<String> roles) {
    final normalized = <String>{};
    for (final role in roles) {
      final cleaned = (role).trim().toLowerCase();
      if (cleaned.isEmpty) continue;
      if (cleaned == 'paused') {
        normalized.add(cleaned);
        continue;
      }
      normalized.add(normalizeRole(cleaned));
    }
    final ordered = normalized.toList()
      ..sort((a, b) {
        final orderDiff = _roleSortOrder(a).compareTo(_roleSortOrder(b));
        if (orderDiff != 0) return orderDiff;
        return a.compareTo(b);
      });
    return ordered;
  }

  static String _normalizeEmail(String? email) {
    return (email ?? '').trim().toLowerCase();
  }

  static bool _isInvitePausedStatus(String? rawStatus) {
    final normalized = (rawStatus ?? '').trim().toLowerCase();
    return normalized == 'revoked' || normalized == 'paused';
  }

  static Future<bool> hasAccessControlTables() async {
    final cached = _hasAccessControlTables;
    if (cached != null) return cached;
    try {
      await _supabase.from('project_members').select('id').limit(1);
      await _supabase.from('project_access_invites').select('id').limit(1);
      _hasAccessControlTables = true;
      return true;
    } catch (_) {
      _hasAccessControlTables = false;
      return false;
    }
  }

  static Future<bool> createOrUpdateInvite({
    required String projectId,
    required String email,
    required String role,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedEmail = _normalizeEmail(email);
    final normalizedRole = normalizeRole(role);
    final requestedBy = _supabase.auth.currentUser?.id;
    if (normalizedProjectId.isEmpty ||
        normalizedEmail.isEmpty ||
        requestedBy == null ||
        requestedBy.trim().isEmpty) {
      return false;
    }
    if (!await hasAccessControlTables()) return false;

    try {
      await _supabase.from('project_access_invites').upsert(
        <String, dynamic>{
          'project_id': normalizedProjectId,
          'invited_email': normalizedEmail,
          'role': normalizedRole,
          'status': 'requested',
          'requested_by': requestedBy,
          'requested_at': DateTime.now().toIso8601String(),
          'accepted_at': null,
          'accepted_user_id': null,
          'updated_at': DateTime.now().toIso8601String(),
        },
        onConflict: 'project_id,invited_email,role',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setInvitePaused({
    required String projectId,
    required String email,
    required String role,
    required bool paused,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedEmail = _normalizeEmail(email);
    final normalizedRole = normalizeRole(role);
    if (normalizedProjectId.isEmpty || normalizedEmail.isEmpty) {
      return false;
    }
    if (!await hasAccessControlTables()) return false;

    final nowIso = DateTime.now().toIso8601String();
    final nextInviteStatus = paused ? 'revoked' : 'accepted';
    final nextMemberRole = paused ? 'partner' : normalizedRole;
    String acceptedUserId = '';

    try {
      final invite = await _supabase
          .from('project_access_invites')
          .select('accepted_user_id')
          .eq('project_id', normalizedProjectId)
          .eq('invited_email', normalizedEmail)
          .eq('role', normalizedRole)
          .order('requested_at', ascending: false)
          .limit(1)
          .maybeSingle();
      acceptedUserId = (invite?['accepted_user_id'] ?? '').toString().trim();
    } catch (_) {
      // Best-effort update below still applies.
    }

    try {
      final invitePatch = <String, dynamic>{
        'status': nextInviteStatus,
        'updated_at': nowIso,
      };
      if (!paused) {
        invitePatch['accepted_at'] = nowIso;
        if (acceptedUserId.isNotEmpty) {
          invitePatch['accepted_user_id'] = acceptedUserId;
        }
      }
      await _supabase
          .from('project_access_invites')
          .update(invitePatch)
          .eq('project_id', normalizedProjectId)
          .eq('invited_email', normalizedEmail)
          .eq('role', normalizedRole);
    } catch (_) {
      return false;
    }

    try {
      final memberPatch = <String, dynamic>{
        'role': nextMemberRole,
        'status': 'active',
        'updated_at': nowIso,
      };
      await _supabase
          .from('project_members')
          .update(memberPatch)
          .eq('project_id', normalizedProjectId)
          .eq('invited_email', normalizedEmail);
      if (acceptedUserId.isNotEmpty) {
        await _supabase
            .from('project_members')
            .update(memberPatch)
            .eq('project_id', normalizedProjectId)
            .eq('user_id', acceptedUserId);
      }
    } catch (_) {
      // Keep invite status as source of truth for pause/resume.
    }

    return true;
  }

  static Future<bool> removeInviteAccess({
    required String projectId,
    required String email,
    required String role,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedEmail = _normalizeEmail(email);
    final normalizedRole = normalizeRole(role);
    if (normalizedProjectId.isEmpty || normalizedEmail.isEmpty) {
      return false;
    }
    if (!await hasAccessControlTables()) return false;

    String acceptedUserId = '';
    try {
      final invite = await _supabase
          .from('project_access_invites')
          .select('accepted_user_id')
          .eq('project_id', normalizedProjectId)
          .eq('invited_email', normalizedEmail)
          .eq('role', normalizedRole)
          .order('requested_at', ascending: false)
          .limit(1)
          .maybeSingle();
      acceptedUserId = (invite?['accepted_user_id'] ?? '').toString().trim();
    } catch (_) {
      acceptedUserId = '';
    }

    try {
      await _supabase
          .from('project_access_invites')
          .delete()
          .eq('project_id', normalizedProjectId)
          .eq('invited_email', normalizedEmail)
          .eq('role', normalizedRole);
    } catch (_) {
      return false;
    }

    try {
      final remainingInvites = await _supabase
          .from('project_access_invites')
          .select('id')
          .eq('project_id', normalizedProjectId)
          .eq('invited_email', normalizedEmail)
          .limit(1);
      final hasRemainingInvites = remainingInvites.isNotEmpty;
      if (!hasRemainingInvites) {
        await _supabase
            .from('project_members')
            .delete()
            .eq('project_id', normalizedProjectId)
            .eq('invited_email', normalizedEmail);
        if (acceptedUserId.isNotEmpty) {
          await _supabase
              .from('project_members')
              .delete()
              .eq('project_id', normalizedProjectId)
              .eq('user_id', acceptedUserId);
        }
      }
    } catch (_) {
      // Best effort cleanup after invite removal.
    }

    return true;
  }

  static Future<String?> resolveCurrentUserRoleForProject({
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    final userId = _supabase.auth.currentUser?.id;
    if (normalizedProjectId.isEmpty ||
        userId == null ||
        userId.trim().isEmpty) {
      return null;
    }

    try {
      final project = await _supabase
          .from('projects')
          .select('user_id')
          .eq('id', normalizedProjectId)
          .maybeSingle();
      final ownerId = (project?['user_id'] ?? '').toString().trim();
      if (ownerId.isNotEmpty && ownerId == userId) {
        return 'owner';
      }
    } catch (_) {
      // Fall through to member lookup.
    }

    if (!await hasAccessControlTables()) return null;

    try {
      final member = await _supabase
          .from('project_members')
          .select('role, status')
          .eq('project_id', normalizedProjectId)
          .eq('user_id', userId)
          .maybeSingle();
      if (member == null) return null;
      final status = (member['status'] ?? '').toString().trim().toLowerCase();
      if (status.isNotEmpty && status != 'active') return null;
      final memberRole = normalizeRole(member['role']?.toString());

      final email = _normalizeEmail(_supabase.auth.currentUser?.email);
      if (email.isEmpty) return memberRole;
      try {
        final invite = await _supabase
            .from('project_access_invites')
            .select('status')
            .eq('project_id', normalizedProjectId)
            .eq('invited_email', email)
            .order('requested_at', ascending: false)
            .limit(1)
            .maybeSingle();
        if (_isInvitePausedStatus(invite?['status']?.toString())) {
          return 'paused';
        }
      } catch (_) {
        // Ignore invite lookup issues and return membership role.
      }

      return memberRole;
    } catch (_) {
      return null;
    }
  }

  static Future<List<String>> resolveCurrentUserRolesForProject({
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    final currentUser = _supabase.auth.currentUser;
    final userId = currentUser?.id;
    final email = _normalizeEmail(currentUser?.email);
    if (normalizedProjectId.isEmpty ||
        userId == null ||
        userId.trim().isEmpty) {
      return const <String>[];
    }

    final roles = <String>{};

    try {
      final project = await _supabase
          .from('projects')
          .select('user_id')
          .eq('id', normalizedProjectId)
          .maybeSingle();
      final ownerId = (project?['user_id'] ?? '').toString().trim();
      if (ownerId.isNotEmpty && ownerId == userId) {
        roles.add('owner');
      }
    } catch (_) {
      // Fall through to membership/invite role lookup.
    }

    if (!await hasAccessControlTables()) {
      return sortRolesForUi(roles);
    }

    try {
      final memberRows = await _supabase
          .from('project_members')
          .select('role, status')
          .eq('project_id', normalizedProjectId)
          .eq('user_id', userId);
      for (final row in memberRows) {
        final status = (row['status'] ?? '').toString().trim().toLowerCase();
        if (status.isNotEmpty && status != 'active') continue;
        final role = normalizeRole(row['role']?.toString());
        if (role.isNotEmpty) {
          roles.add(role);
        }
      }
    } catch (_) {
      // Best-effort; keep resolved roles from other sources.
    }

    if (email.isNotEmpty) {
      try {
        final inviteRows = await _supabase
            .from('project_access_invites')
            .select('role, status, accepted_user_id')
            .eq('project_id', normalizedProjectId)
            .eq('invited_email', email);

        for (final row in inviteRows) {
          final status = (row['status'] ?? '').toString().trim().toLowerCase();
          if (status.isEmpty) continue;
          if (_isInvitePausedStatus(status) || status == 'expired') continue;

          final acceptedUserId =
              (row['accepted_user_id'] ?? '').toString().trim();
          final isAccepted = status == 'accepted' || status == 'active';
          final isAcceptedByCurrentUser =
              acceptedUserId.isNotEmpty && acceptedUserId == userId;
          if (!isAccepted && !isAcceptedByCurrentUser) continue;

          final role = normalizeRole(row['role']?.toString());
          if (role.isNotEmpty) {
            roles.add(role);
          }
        }
      } catch (_) {
        // Best-effort; membership roles may still be enough.
      }
    }

    return sortRolesForUi(roles);
  }

  static Future<String?> acceptPendingInviteForCurrentUser({
    required String projectId,
    String? roleHint,
  }) async {
    final normalizedProjectId = projectId.trim();
    final currentUser = _supabase.auth.currentUser;
    final userId = currentUser?.id;
    final email = _normalizeEmail(currentUser?.email);
    if (normalizedProjectId.isEmpty ||
        userId == null ||
        userId.trim().isEmpty ||
        email.isEmpty) {
      return null;
    }
    if (!await hasAccessControlTables()) return null;

    final normalizedRoleHint = roleHint == null ? '' : normalizeRole(roleHint);
    Map<String, dynamic>? invite;

    try {
      if (normalizedRoleHint.isNotEmpty) {
        invite = await _supabase
            .from('project_access_invites')
            .select('id, role, status')
            .eq('project_id', normalizedProjectId)
            .eq('invited_email', email)
            .eq('role', normalizedRoleHint)
            .order('requested_at', ascending: false)
            .limit(1)
            .maybeSingle();
      } else {
        invite = await _supabase
            .from('project_access_invites')
            .select('id, role, status')
            .eq('project_id', normalizedProjectId)
            .eq('invited_email', email)
            .order('requested_at', ascending: false)
            .limit(1)
            .maybeSingle();
      }
    } catch (_) {
      invite = null;
    }

    if (invite == null) {
      return resolveCurrentUserRoleForProject(projectId: normalizedProjectId);
    }

    final inviteId = (invite['id'] ?? '').toString().trim();
    final resolvedRole = normalizeRole(invite['role']?.toString());
    final status = (invite['status'] ?? '').toString().trim().toLowerCase();
    final nowIso = DateTime.now().toIso8601String();

    if (_isInvitePausedStatus(status) || status == 'expired') {
      return resolveCurrentUserRoleForProject(projectId: normalizedProjectId);
    }

    if (inviteId.isNotEmpty && status == 'requested') {
      try {
        await _supabase.from('project_access_invites').update(<String, dynamic>{
          'status': 'accepted',
          'accepted_at': nowIso,
          'accepted_user_id': userId,
          'updated_at': nowIso,
        }).eq('id', inviteId);
      } catch (_) {
        // Continue; membership upsert may still succeed.
      }
    }

    try {
      await _supabase.from('project_members').upsert(
        <String, dynamic>{
          'project_id': normalizedProjectId,
          'user_id': userId,
          'invited_email': email,
          'role': resolvedRole,
          'status': 'active',
          'accepted_at': nowIso,
          'updated_at': nowIso,
        },
        onConflict: 'project_id,user_id',
      );
    } catch (_) {
      // If upsert fails, role resolution below returns best-known role.
    }

    final refreshedRole = await resolveCurrentUserRoleForProject(
      projectId: normalizedProjectId,
    );
    return refreshedRole ?? resolvedRole;
  }
}
