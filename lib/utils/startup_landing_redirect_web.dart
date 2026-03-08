import 'dart:html' as html;

Future<bool> redirectToLandingIfNeeded() async {
  final uri = Uri.base;
  final path = uri.path;

  final isRootPath = path.isEmpty || path == '/' || path == '/index.html';
  if (!isRootPath) return false;

  const target = '/website_8answers%20copy%202/index.html';
  final current = html.window.location.pathname ?? '';
  if (current.contains('/website_8answers%20copy%202/') ||
      current.contains('/website_8answers copy 2/')) {
    return false;
  }

  html.window.location.replace(target);
  return true;
}
