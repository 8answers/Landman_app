import 'dart:html' as html;

Future<bool> isReloadNavigation() async {
  try {
    final performance = html.window.performance;

    // Legacy API still available in browsers used by Flutter web.
    final legacyNavigation = performance.navigation;
    return legacyNavigation.type == 1;
  } catch (_) {
    // If navigation type can't be determined, treat as fresh open.
  }

  return false;
}

void replaceBrowserPath(String path) {
  final raw = path.trim();
  if (raw.isEmpty) return;
  var normalized = raw.startsWith('/') ? raw : '/$raw';
  normalized = normalized.replaceAll(RegExp(r'/+'), '/');

  try {
    final currentPath = html.window.location.pathname ?? '/';
    if (currentPath == normalized) return;
    html.window.history.replaceState(null, '', normalized);
  } catch (_) {
    // Best-effort URL sync.
  }
}
