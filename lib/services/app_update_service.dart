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

    int scoreForPlatform(_ReleaseAssetPick asset, String p) {
      final name = asset.name.toLowerCase();
      final hasSetupOrInstaller =
          name.contains('setup') || name.contains('installer');

      switch (p) {
        case 'windows':
          if (name.endsWith('.msi')) return 120;
          if (name.endsWith('.exe')) return hasSetupOrInstaller ? 110 : 100;
          if (name.endsWith('.zip') && name.contains('windows')) return 80;
          if (name.endsWith('.zip')) return 70;
          return 0;
        case 'macos':
        case 'mac':
        case 'osx':
          if (name.endsWith('.pkg')) return 120;
          if (name.endsWith('.dmg')) return 110;
          if (name.endsWith('.zip') &&
              (name.contains('macos') ||
                  RegExp(r'\bmac\b').hasMatch(name) ||
                  name.contains('osx'))) {
            return 80;
          }
          if (name.endsWith('.zip')) return 70;
          return 0;
        case 'linux':
          if (name.endsWith('.appimage')) return 120;
          if (name.endsWith('.deb') || name.endsWith('.rpm')) return 110;
          if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) return 90;
          if (name.endsWith('.zip') && name.contains('linux')) return 80;
          if (name.endsWith('.zip')) return 70;
          return 0;
        case 'android':
          if (name.endsWith('.apk')) return 120;
          if (name.contains('android')) return 80;
          return 0;
        case 'ios':
          // iOS generally updates via App Store / MDM; assets here are uncommon.
          if (name.contains('ios')) return 80;
          return 0;
        default:
          return 0;
      }
    }

    _ReleaseAssetPick? best;
    var bestScore = 0;
    for (final candidate in candidates) {
      final score = scoreForPlatform(candidate, platform);
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }

    return bestScore > 0 ? best : null;
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
