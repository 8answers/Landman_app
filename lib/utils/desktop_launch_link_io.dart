import 'dart:io';

Uri? getInitialDesktopLaunchUriImpl() {
  for (final rawArg in Platform.executableArguments) {
    final candidate = rawArg.trim();
    if (candidate.isEmpty) continue;
    final uri = Uri.tryParse(candidate);
    if (uri == null) continue;
    final scheme = uri.scheme.trim().toLowerCase();
    if (scheme == 'com.example.landmanwebsite' || scheme == '8answers') {
      return uri;
    }
  }
  return null;
}
