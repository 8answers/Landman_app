// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

bool _hasAuthFlowParams(Uri uri) {
  final queryParams = uri.queryParameters;
  final hashValue = html.window.location.hash;
  final hashQuery = hashValue.startsWith('#') ? hashValue.substring(1) : '';
  final hashParams = Uri.splitQueryString(
    hashQuery.contains('=') ? hashQuery : '',
  );
  return queryParams.containsKey('code') ||
      queryParams.containsKey('state') ||
      queryParams.containsKey('access_token') ||
      queryParams.containsKey('refresh_token') ||
      queryParams.containsKey('id_token') ||
      queryParams.containsKey('auth') ||
      queryParams.containsKey('invite') ||
      queryParams.containsKey('projectId') ||
      queryParams.containsKey('inv') ||
      queryParams.containsKey('inviteToken') ||
      hashParams.containsKey('access_token') ||
      hashParams.containsKey('refresh_token') ||
      hashParams.containsKey('id_token');
}

String _normalizedLastSegment(String path) {
  var normalized = path.trim();
  if (normalized.isEmpty) return '';
  if (normalized.endsWith('/index.html')) {
    normalized =
        normalized.substring(0, normalized.length - '/index.html'.length);
  }
  try {
    normalized = Uri.decodeComponent(normalized);
  } catch (_) {
    // Keep original value when decoding fails.
  }
  final segments = normalized
      .split('/')
      .where((segment) => segment.trim().isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty) return '';
  return segments.last.trim().toLowerCase();
}

bool _isKnownAppShellPath(String path) {
  const knownRoutes = <String>{
    'dashboard',
    'dataentry',
    'data-entry',
    'data entry',
    'plotstatus',
    'plot-status',
    'plot status',
    'documents',
    'report',
    'reports',
    'settings',
    'recent',
    'recentprojects',
    'recent-projects',
    'allprojects',
    'all-projects',
    'account',
    'notifications',
    'todo',
    'to-do',
    'to-do-list',
    'todolist',
    'help',
    'trash',
    'logout',
  };
  return knownRoutes.contains(_normalizedLastSegment(path));
}

bool _isLandingPath(String path) {
  final lowerPath = path.toLowerCase();
  return lowerPath.contains('/website_8answers%20copy%202/') ||
      lowerPath.contains('/website_8answers copy 2/');
}

String _resolveAppBasePath(String path) {
  var resolved = path.isEmpty ? '/' : path;
  final lowerPath = resolved.toLowerCase();
  final encodedIndex = lowerPath.indexOf('/website_8answers%20copy%202/');
  final decodedIndex = lowerPath.indexOf('/website_8answers copy 2/');
  final segmentIndex = encodedIndex >= 0
      ? encodedIndex
      : decodedIndex >= 0
          ? decodedIndex
          : -1;

  if (segmentIndex >= 0) {
    resolved = resolved.substring(0, segmentIndex + 1);
  } else if (resolved.endsWith('/index.html')) {
    resolved = resolved.substring(0, resolved.length - '/index.html'.length);
  } else if (!resolved.endsWith('/')) {
    final lastSlash = resolved.lastIndexOf('/');
    resolved = lastSlash >= 0 ? resolved.substring(0, lastSlash + 1) : '/';
  }

  if (!resolved.startsWith('/')) resolved = '/$resolved';
  if (!resolved.endsWith('/')) resolved = '$resolved/';
  return resolved;
}

Future<bool> redirectToLandingIfNeeded() async {
  final uri = Uri.base;
  final path = uri.path;
  if (_hasAuthFlowParams(uri)) return false;
  if (_isLandingPath(path)) return false;

  final isRootPath = path.isEmpty || path == '/' || path == '/index.html';
  final isKnownAppPath = _isKnownAppShellPath(path);
  if (!isRootPath && !isKnownAppPath) return false;

  final appBasePath = _resolveAppBasePath(path);
  final startupUrl =
      '${appBasePath}website_8answers%20copy%202/index.html?v=20260401';
  html.window.location.replace(startupUrl);
  return true;
}
