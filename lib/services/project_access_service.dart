import 'package:supabase_flutter/supabase_flutter.dart';

enum ProjectDeleteOutcome {
  deletedForEveryone,
  removedForCurrentUser,
}

class ProjectDeleteResult {
  const ProjectDeleteResult({
    required this.outcome,
    required this.role,
  });

  final ProjectDeleteOutcome outcome;
  final String role;

  bool get deletedForEveryone =>
      outcome == ProjectDeleteOutcome.deletedForEveryone;
}

class ProjectRoleLookupResult {
  const ProjectRoleLookupResult({
    required this.roles,
    required this.hadQueryErrors,
  });

  final List<String> roles;
  final bool hadQueryErrors;

  String? get primaryRole => roles.isEmpty ? null : roles.first;
}

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

  static String normalizeRoleStrict(String? rawRole) {
    final normalized = (rawRole ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'partner':
      case 'project_manager':
      case 'agent':
      case 'admin':
      case 'owner':
        return normalized;
      default:
        return '';
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

  static Future<ProjectDeleteResult> deleteProjectForCurrentUser({
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    final currentUser = _supabase.auth.currentUser;
    final userId = (currentUser?.id ?? '').trim();
    final email = _normalizeEmail(currentUser?.email);
    if (normalizedProjectId.isEmpty || userId.isEmpty) {
      throw Exception('User not authenticated');
    }

    final resolvedRole = await resolveCurrentUserRoleForProject(
      projectId: normalizedProjectId,
    );
    final normalizedRole = (resolvedRole ?? '').trim().toLowerCase();
    final canDeleteForEveryone =
        normalizedRole == 'owner' || normalizedRole == 'admin';

    if (canDeleteForEveryone) {
      await _supabase.from('projects').delete().eq('id', normalizedProjectId);
      return ProjectDeleteResult(
        outcome: ProjectDeleteOutcome.deletedForEveryone,
        role: normalizedRole,
      );
    }

    if (!await hasAccessControlTables()) {
      throw Exception(
          'Project access control tables are missing. Cannot remove user access.');
    }

    var membershipUpdatedOrRemoved = false;
    var inviteUpdatedOrRemoved = false;

    try {
      await _supabase
          .from('project_members')
          .delete()
          .eq('project_id', normalizedProjectId)
          .eq('user_id', userId);
      membershipUpdatedOrRemoved = true;
    } catch (_) {
      // Fallback to status update if delete policy is not available.
      try {
        await _supabase
            .from('project_members')
            .update(<String, dynamic>{
              'status': 'inactive',
              'updated_at': DateTime.now().toIso8601String(),
            })
            .eq('project_id', normalizedProjectId)
            .eq('user_id', userId);
        membershipUpdatedOrRemoved = true;
      } catch (_) {
        membershipUpdatedOrRemoved = false;
      }
    }

    if (email.isNotEmpty) {
      try {
        await _supabase
            .from('project_access_invites')
            .delete()
            .eq('project_id', normalizedProjectId)
            .eq('accepted_user_id', userId);
        inviteUpdatedOrRemoved = true;
      } catch (_) {
        // Continue with invited_email-based fallback below.
      }
      try {
        await _supabase
            .from('project_access_invites')
            .delete()
            .eq('project_id', normalizedProjectId)
            .eq('invited_email', email);
        inviteUpdatedOrRemoved = true;
      } catch (_) {
        // Fallback to revoked status if delete policy is not available.
        try {
          await _supabase
              .from('project_access_invites')
              .update(<String, dynamic>{
                'status': 'revoked',
                'updated_at': DateTime.now().toIso8601String(),
              })
              .eq('project_id', normalizedProjectId)
              .eq('invited_email', email);
          inviteUpdatedOrRemoved = true;
        } catch (_) {
          inviteUpdatedOrRemoved = false;
        }
      }
    } else {
      try {
        await _supabase
            .from('project_access_invites')
            .delete()
            .eq('project_id', normalizedProjectId)
            .eq('accepted_user_id', userId);
        inviteUpdatedOrRemoved = true;
      } catch (_) {
        inviteUpdatedOrRemoved = false;
      }
    }

    if (!membershipUpdatedOrRemoved && !inviteUpdatedOrRemoved) {
      throw Exception('Unable to remove your project access.');
    }

    return ProjectDeleteResult(
      outcome: ProjectDeleteOutcome.removedForCurrentUser,
      role: normalizedRole,
    );
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
    var nextMemberStatus = paused ? 'revoked' : 'active';
    var nextMemberRole = normalizedRole;
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

    if (paused) {
      try {
        final remainingInviteRows = await _supabase
            .from('project_access_invites')
            .select('role, status')
            .eq('project_id', normalizedProjectId)
            .eq('invited_email', normalizedEmail);
        final remainingRoles = <String>{};
        for (final row in remainingInviteRows) {
          final inviteRole = normalizeRoleStrict(row['role']?.toString());
          if (inviteRole.isEmpty || inviteRole == normalizedRole) continue;
          final inviteStatus =
              (row['status'] ?? '').toString().trim().toLowerCase();
          if (inviteStatus == 'accepted' || inviteStatus == 'active') {
            remainingRoles.add(inviteRole);
          }
        }
        if (remainingRoles.isNotEmpty) {
          nextMemberStatus = 'active';
          nextMemberRole = sortRolesForUi(remainingRoles).first;
        }
      } catch (_) {
        // Best effort; default to revoked when no active role can be proven.
      }
    }

    try {
      final memberPatch = <String, dynamic>{
        'role': nextMemberRole,
        'status': nextMemberStatus,
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
    final memberUserIdsForSync = <String>{};
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
      if (acceptedUserId.isNotEmpty) {
        memberUserIdsForSync.add(acceptedUserId);
      }
    } catch (_) {
      acceptedUserId = '';
    }

    try {
      final memberRows = await _supabase
          .from('project_members')
          .select('user_id')
          .eq('project_id', normalizedProjectId)
          .ilike('invited_email', normalizedEmail);
      for (final row in memberRows) {
        final memberUserId = (row['user_id'] ?? '').toString().trim();
        if (memberUserId.isNotEmpty) {
          memberUserIdsForSync.add(memberUserId);
        }
      }
    } catch (_) {
      // Best-effort prefetch for stronger cleanup.
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
      final remainingInviteRows = await _supabase
          .from('project_access_invites')
          .select('role, status, accepted_user_id')
          .eq('project_id', normalizedProjectId)
          .eq('invited_email', normalizedEmail);

      final remainingAccessibleRoles = <String>{};
      for (final row in remainingInviteRows) {
        final inviteRole = normalizeRoleStrict(row['role']?.toString());
        final inviteStatus =
            (row['status'] ?? '').toString().trim().toLowerCase();
        final inviteAcceptedUserId =
            (row['accepted_user_id'] ?? '').toString().trim();
        if (inviteAcceptedUserId.isNotEmpty) {
          memberUserIdsForSync.add(inviteAcceptedUserId);
        }
        if (inviteRole.isEmpty) continue;
        if (_isInvitePausedStatus(inviteStatus) || inviteStatus == 'expired') {
          continue;
        }
        final grantsAccess = inviteStatus == 'accepted' ||
            inviteStatus == 'active' ||
            inviteAcceptedUserId.isNotEmpty;
        if (grantsAccess) {
          remainingAccessibleRoles.add(inviteRole);
        }
      }

      final nowIso = DateTime.now().toIso8601String();
      if (remainingAccessibleRoles.isEmpty) {
        // No active role remains for this user: remove or revoke membership
        // so project lists (which query active members) stop showing it.
        try {
          await _supabase
              .from('project_members')
              .delete()
              .eq('project_id', normalizedProjectId)
              .eq('invited_email', normalizedEmail);
        } catch (_) {
          try {
            await _supabase
                .from('project_members')
                .delete()
                .eq('project_id', normalizedProjectId)
                .ilike('invited_email', normalizedEmail);
          } catch (_) {
            // Fall through to revoke fallback.
          }
          try {
            await _supabase
                .from('project_members')
                .update(<String, dynamic>{
                  'status': 'revoked',
                  'updated_at': nowIso,
                })
                .eq('project_id', normalizedProjectId)
                .eq(
                  'invited_email',
                  normalizedEmail,
                );
          } catch (_) {
            try {
              await _supabase
                  .from('project_members')
                  .update(<String, dynamic>{
                    'status': 'revoked',
                    'updated_at': nowIso,
                  })
                  .eq('project_id', normalizedProjectId)
                  .ilike('invited_email', normalizedEmail);
            } catch (_) {
              // Best effort cleanup after invite removal.
            }
          }
        }

        for (final userId in memberUserIdsForSync) {
          try {
            await _supabase
                .from('project_members')
                .delete()
                .eq('project_id', normalizedProjectId)
                .eq('user_id', userId);
          } catch (_) {
            try {
              await _supabase
                  .from('project_members')
                  .update(<String, dynamic>{
                    'status': 'revoked',
                    'updated_at': nowIso,
                  })
                  .eq('project_id', normalizedProjectId)
                  .eq('user_id', userId);
            } catch (_) {
              // Best effort cleanup after invite removal.
            }
          }
        }
      } else {
        final nextMemberRole = sortRolesForUi(remainingAccessibleRoles).first;
        final memberPatch = <String, dynamic>{
          'role': nextMemberRole,
          'status': 'active',
          'updated_at': nowIso,
        };
        try {
          await _supabase
              .from('project_members')
              .update(memberPatch)
              .eq('project_id', normalizedProjectId)
              .eq('invited_email', normalizedEmail);
        } catch (_) {
          // Best effort sync.
        }
        for (final userId in memberUserIdsForSync) {
          try {
            await _supabase
                .from('project_members')
                .update(memberPatch)
                .eq('project_id', normalizedProjectId)
                .eq('user_id', userId);
          } catch (_) {
            // Best effort sync.
          }
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

    final lookup = await resolveCurrentUserRolesForProjectWithDiagnostics(
      projectId: normalizedProjectId,
    );
    return lookup.primaryRole;
  }

  static Future<List<String>> resolveCurrentUserRolesForProject({
    required String projectId,
  }) async {
    final lookup = await resolveCurrentUserRolesForProjectWithDiagnostics(
      projectId: projectId,
    );
    return lookup.roles;
  }

  static Future<ProjectRoleLookupResult>
      resolveCurrentUserRolesForProjectWithDiagnostics({
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    final currentUser = _supabase.auth.currentUser;
    final userId = currentUser?.id;
    final email = _normalizeEmail(currentUser?.email);
    if (normalizedProjectId.isEmpty ||
        userId == null ||
        userId.trim().isEmpty) {
      return const ProjectRoleLookupResult(
        roles: <String>[],
        hadQueryErrors: false,
      );
    }

    final roles = <String>{};
    var hadQueryErrors = false;

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
      hadQueryErrors = true;
    }

    List<dynamic> inviteRows = const <dynamic>[];
    final latestInviteStatusByRole = <String, String>{};
    var inviteLookupFailed = false;

    if (email.isNotEmpty) {
      try {
        inviteRows = await _supabase
            .from('project_access_invites')
            .select('role, status, accepted_user_id, requested_at')
            .eq('project_id', normalizedProjectId)
            .eq('invited_email', email)
            .order('requested_at', ascending: false);

        for (final row in inviteRows) {
          final role = normalizeRoleStrict(row['role']?.toString());
          if (role.isEmpty || latestInviteStatusByRole.containsKey(role)) {
            continue;
          }
          final status = (row['status'] ?? '').toString().trim().toLowerCase();
          if (status.isEmpty) continue;
          latestInviteStatusByRole[role] = status;
        }
      } catch (_) {
        hadQueryErrors = true;
        inviteLookupFailed = true;
        inviteRows = const <dynamic>[];
      }
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
        final role = normalizeRoleStrict(row['role']?.toString());
        if (role.isEmpty) continue;
        final inviteStatus = latestInviteStatusByRole[role];
        if (inviteStatus != null) {
          if (_isInvitePausedStatus(inviteStatus) ||
              inviteStatus == 'expired') {
            continue;
          }
          roles.add(role);
          continue;
        }
        // If invite lookup succeeded and no invite status exists for this role,
        // treat membership as stale and do not grant access from it.
        // Allow membership-only fallback only when invite lookup failed or
        // current account has no usable email.
        final allowMembershipOnlyRole = inviteLookupFailed || email.isEmpty;
        if (!allowMembershipOnlyRole) {
          continue;
        }
        roles.add(role);
      }
    } catch (_) {
      hadQueryErrors = true;
    }

    for (final row in inviteRows) {
      final status = (row['status'] ?? '').toString().trim().toLowerCase();
      if (status.isEmpty) continue;
      if (_isInvitePausedStatus(status) || status == 'expired') continue;

      final acceptedUserId = (row['accepted_user_id'] ?? '').toString().trim();
      final isAccepted = status == 'accepted' || status == 'active';
      final isAcceptedByCurrentUser =
          acceptedUserId.isNotEmpty && acceptedUserId == userId;
      if (!isAccepted && !isAcceptedByCurrentUser) continue;

      final role = normalizeRoleStrict(row['role']?.toString());
      if (role.isNotEmpty) {
        roles.add(role);
      }
    }

    return ProjectRoleLookupResult(
      roles: sortRolesForUi(roles),
      hadQueryErrors: hadQueryErrors,
    );
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
        // Fallback: if role hint is stale/missing from link payload,
        // accept the latest invite for this user/project regardless of role.
        if (invite == null) {
          invite = await _supabase
              .from('project_access_invites')
              .select('id, role, status')
              .eq('project_id', normalizedProjectId)
              .eq('invited_email', email)
              .order('requested_at', ascending: false)
              .limit(1)
              .maybeSingle();
        }
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
