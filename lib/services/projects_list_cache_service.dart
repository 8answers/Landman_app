class _ProjectsCacheEntry {
  _ProjectsCacheEntry(this.projects, this.cachedAt);

  final List<Map<String, dynamic>> projects;
  final DateTime cachedAt;
}

class ProjectsListCacheService {
  static final Map<String, _ProjectsCacheEntry> _recentProjectsByUser = {};
  static final Map<String, _ProjectsCacheEntry> _allProjectsByUser = {};

  static List<Map<String, dynamic>>? getRecentProjects(
    String userId, {
    Duration? maxAge,
  }) {
    final entry = _recentProjectsByUser[userId];
    if (entry == null) return null;
    if (_isExpired(entry, maxAge)) return null;
    return _cloneProjects(entry.projects);
  }

  static List<Map<String, dynamic>>? getAllProjects(
    String userId, {
    Duration? maxAge,
  }) {
    final entry = _allProjectsByUser[userId];
    if (entry == null) return null;
    if (_isExpired(entry, maxAge)) return null;
    return _cloneProjects(entry.projects);
  }

  static void setRecentProjects(
      String userId, List<Map<String, dynamic>> projects) {
    _recentProjectsByUser[userId] = _ProjectsCacheEntry(
      _cloneProjects(projects),
      DateTime.now(),
    );
  }

  static void setAllProjects(
      String userId, List<Map<String, dynamic>> projects) {
    _allProjectsByUser[userId] = _ProjectsCacheEntry(
      _cloneProjects(projects),
      DateTime.now(),
    );
  }

  static void invalidateUser(String userId) {
    _recentProjectsByUser.remove(userId);
    _allProjectsByUser.remove(userId);
  }

  static bool _isExpired(_ProjectsCacheEntry entry, Duration? maxAge) {
    if (maxAge == null) return false;
    return DateTime.now().difference(entry.cachedAt) > maxAge;
  }

  static List<Map<String, dynamic>> _cloneProjects(
    List<Map<String, dynamic>> projects,
  ) {
    return projects
        .map((project) => Map<String, dynamic>.from(project))
        .toList(growable: false);
  }
}
