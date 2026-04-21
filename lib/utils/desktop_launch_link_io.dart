import 'dart:io';

List<String> _initialDesktopLaunchArgs = const <String>[];

void registerInitialDesktopLaunchArgs(List<String> args) {
  _initialDesktopLaunchArgs = List<String>.from(args);
}

Uri? getInitialDesktopLaunchUriImpl() {
  final launchArgs = _initialDesktopLaunchArgs.isNotEmpty
      ? _initialDesktopLaunchArgs
      : Platform.executableArguments;
  for (final rawArg in launchArgs) {
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
