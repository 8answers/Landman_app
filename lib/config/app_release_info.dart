class AppReleaseInfo {
  const AppReleaseInfo._();

  // Set per build using:
  // --dart-define=APP_RELEASE_VERSION=1.2.16
  static const String rawVersion = String.fromEnvironment(
    'APP_RELEASE_VERSION',
    defaultValue: '1.2.15',
  );

  static String get normalizedVersion {
    var value = rawVersion.trim();
    if (value.toLowerCase().startsWith('v')) {
      value = value.substring(1);
    }
    final plusIndex = value.indexOf('+');
    if (plusIndex >= 0) {
      value = value.substring(0, plusIndex);
    }
    return value;
  }

  static String get displayVersion {
    final normalized = normalizedVersion;
    if (normalized.isEmpty) return 'v0.0.0';
    return 'v$normalized';
  }
}
