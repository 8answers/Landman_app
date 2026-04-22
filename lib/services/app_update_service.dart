import 'dart:convert';

import 'package:http/http.dart' as http;
import '../config/app_release_info.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUrl,
    this.downloadUrl,
    this.assetName,
    this.releaseNotes,
    this.publishedAt,
  });

  final String currentVersion;
  final String latestVersion;
  // HTML release page (fallback when a direct asset download isn't available).
  final String releaseUrl;
  // Direct asset URL (e.g. .dmg/.zip/.exe) when determinable.
  final String? downloadUrl;
  final String? assetName;
  final String? releaseNotes;
  final DateTime? publishedAt;
}

class AppUpdateService {
  const AppUpdateService._();

  // Override when needed with --dart-define=APP_UPDATE_FEED_URL=<url>
  static const String _latestReleaseApiUrl = String.fromEnvironment(
    'APP_UPDATE_FEED_URL',
    defaultValue:
        'https://api.github.com/repos/8answers/Landman_app/releases/latest',
  );

  static Future<AppUpdateInfo?> checkForUpdate({String? platform}) async {
    final current = _normalizeVersion(AppReleaseInfo.normalizedVersion);
    if (current.isEmpty) return null;

    try {
      final response = await http.get(
        Uri.parse(_latestReleaseApiUrl),
        headers: const <String, String>{
          'Accept': 'application/vnd.github+json',
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final payload = Map<String, dynamic>.from(decoded);

      final rawLatest =
          (payload['tag_name'] ?? payload['name'] ?? '').toString().trim();
      final latest = _normalizeVersion(rawLatest);
      if (latest.isEmpty || !_isVersionNewer(latest, current)) {
        return null;
      }

      final releaseUrl = (payload['html_url'] ?? '').toString().trim();
      if (releaseUrl.isEmpty) return null;

      final releaseNotes = (payload['body'] ?? '').toString().trim();
      final publishedAtRaw = (payload['published_at'] ?? '').toString().trim();
      final publishedAt = DateTime.tryParse(publishedAtRaw);

      final normalizedPlatform = (platform ?? '').trim().toLowerCase();
      final assets = payload['assets'];
      final assetPick = _pickAssetForPlatform(assets, normalizedPlatform);

      return AppUpdateInfo(
        currentVersion: current,
        latestVersion: latest,
        releaseUrl: releaseUrl,
        downloadUrl: assetPick?.downloadUrl,
        assetName: assetPick?.name,
        releaseNotes: releaseNotes.isEmpty ? null : releaseNotes,
        publishedAt: publishedAt,
      );
    } catch (_) {
      return null;
    }
  }

  static String _normalizeVersion(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    if (value.toLowerCase().startsWith('v')) {
      value = value.substring(1);
    }
    final plusIndex = value.indexOf('+');
    if (plusIndex >= 0) {
      value = value.substring(0, plusIndex);
    }
    return value;
  }

  static bool _isVersionNewer(String candidate, String baseline) {
    final candidateParts = _parseVersionParts(candidate);
    final baselineParts = _parseVersionParts(baseline);
    final maxLen = candidateParts.length > baselineParts.length
        ? candidateParts.length
        : baselineParts.length;

    for (var i = 0; i < maxLen; i++) {
      final a = i < candidateParts.length ? candidateParts[i] : 0;
      final b = i < baselineParts.length ? baselineParts[i] : 0;
      if (a > b) return true;
      if (a < b) return false;
    }

    return false;
  }

  static List<int> _parseVersionParts(String raw) {
    return raw.split('.').map((part) {
      final digits = RegExp(r'^\d+').stringMatch(part.trim()) ?? '0';
      return int.tryParse(digits) ?? 0;
    }).toList(growable: false);
  }

  static _ReleaseAssetPick? _pickAssetForPlatform(
    dynamic rawAssets,
    String platform,
  ) {
    if (rawAssets is! List) return null;
    final candidates = rawAssets
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw))
        .map(_ReleaseAssetPick.fromGitHub)
        .where((asset) => asset.downloadUrl.isNotEmpty && asset.name.isNotEmpty)
        .toList(growable: false);
    if (candidates.isEmpty) return null;

    // If platform isn't provided, only pick when there's exactly one asset
    // to avoid sending users to the wrong installer.
    if (platform.isEmpty) {
      return candidates.length == 1 ? candidates.first : null;
    }

    bool matchAny(_ReleaseAssetPick asset, List<RegExp> patterns) {
      final name = asset.name.toLowerCase();
      return patterns.any((re) => re.hasMatch(name));
    }

    List<RegExp> patternsForPlatform(String p) {
      switch (p) {
        case 'windows':
          return [
            RegExp(r'windows'),
            RegExp(r'\.msi$'),
            RegExp(r'\.exe$'),
            RegExp(r'\.zip$'),
          ];
        case 'macos':
        case 'mac':
        case 'osx':
          return [
            RegExp(r'macos'),
            RegExp(r'\bmac\b'),
            RegExp(r'osx'),
            RegExp(r'\.dmg$'),
            RegExp(r'\.pkg$'),
            RegExp(r'\.zip$'),
          ];
        case 'linux':
          return [
            RegExp(r'linux'),
            RegExp(r'\.appimage$'),
            RegExp(r'\.deb$'),
            RegExp(r'\.rpm$'),
            RegExp(r'\.tar\.gz$'),
            RegExp(r'\.tgz$'),
            RegExp(r'\.zip$'),
          ];
        case 'android':
          return [
            RegExp(r'android'),
            RegExp(r'\.apk$'),
          ];
        case 'ios':
          // iOS generally updates via App Store / MDM; assets here are uncommon.
          return [RegExp(r'ios')];
        default:
          return [];
      }
    }

    final patterns = patternsForPlatform(platform);
    if (patterns.isNotEmpty) {
      final matched = candidates.where((a) => matchAny(a, patterns)).toList();
      if (matched.isNotEmpty) {
        // Prefer the first match as authored on the release.
        return matched.first;
      }
    }

    // If nothing matches, don't guess—keep the release page fallback.
    return null;
  }
}

class _ReleaseAssetPick {
  const _ReleaseAssetPick({required this.name, required this.downloadUrl});

  final String name;
  final String downloadUrl;

  static _ReleaseAssetPick fromGitHub(Map<String, dynamic> asset) {
    return _ReleaseAssetPick(
      name: (asset['name'] ?? '').toString().trim(),
      downloadUrl: (asset['browser_download_url'] ?? '').toString().trim(),
    );
  }
}
