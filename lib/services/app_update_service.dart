import 'dart:convert';

import 'package:http/http.dart' as http;
import '../config/app_release_info.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUrl,
    this.releaseNotes,
    this.publishedAt,
  });

  final String currentVersion;
  final String latestVersion;
  final String releaseUrl;
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

  static Future<AppUpdateInfo?> checkForUpdate() async {
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

      return AppUpdateInfo(
        currentVersion: current,
        latestVersion: latest,
        releaseUrl: releaseUrl,
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
      final digits = RegExp(r'^\\d+').stringMatch(part.trim()) ?? '0';
      return int.tryParse(digits) ?? 0;
    }).toList(growable: false);
  }
}
