import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'app_update_service.dart';

Future<bool> tryRunInstallerImpl(AppUpdateInfo updateInfo) async {
  final rawUrl = (updateInfo.downloadUrl ?? '').trim();
  if (rawUrl.isEmpty) return false;

  final uri = Uri.tryParse(rawUrl);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;

  final extension = _assetExtension(
    name: (updateInfo.assetName ?? '').trim(),
    path: uri.path,
  );
  if (!_isSupportedInstallerAsset(extension)) return false;

  try {
    final bytes = await _downloadInstaller(uri);
    if (bytes == null || bytes.isEmpty) return false;

    final targetName = _resolvedAssetName(
      preferredName: (updateInfo.assetName ?? '').trim(),
      uriPath: uri.path,
      extension: extension,
    );
    final outputPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}$targetName';
    final outputFile = File(outputPath);

    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsBytes(bytes, flush: true);

    return await _launchInstaller(
      installerPath: outputFile.path,
      extension: extension,
    );
  } catch (_) {
    return false;
  }
}

String _assetExtension({required String name, required String path}) {
  final source = name.isNotEmpty ? name.toLowerCase() : path.toLowerCase();
  if (source.endsWith('.msi')) return '.msi';
  if (source.endsWith('.exe')) return '.exe';
  if (source.endsWith('.pkg')) return '.pkg';
  if (source.endsWith('.dmg')) return '.dmg';
  return '';
}

bool _isSupportedInstallerAsset(String extension) {
  if (extension.isEmpty) return false;
  if (Platform.isWindows) {
    return extension == '.msi' || extension == '.exe';
  }
  if (Platform.isMacOS) {
    return extension == '.pkg' || extension == '.dmg';
  }
  return false;
}

String _resolvedAssetName({
  required String preferredName,
  required String uriPath,
  required String extension,
}) {
  final fromName = preferredName.trim();
  if (fromName.isNotEmpty) return fromName;

  final fromUri = uriPath.split('/').where((part) => part.trim().isNotEmpty);
  if (fromUri.isNotEmpty) return fromUri.last;

  final stamp = DateTime.now().millisecondsSinceEpoch;
  return '8answers_update_$stamp$extension';
}

Future<Uint8List?> _downloadInstaller(Uri uri) async {
  final response = await http.get(
    uri,
    headers: const <String, String>{
      'Accept': 'application/octet-stream',
    },
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    return null;
  }
  final bytes = response.bodyBytes;
  if (bytes.isEmpty) return null;
  return bytes;
}

Future<bool> _launchInstaller({
  required String installerPath,
  required String extension,
}) async {
  try {
    if (Platform.isWindows) {
      if (extension == '.msi') {
        await Process.start(
          'msiexec',
          <String>['/i', installerPath],
          mode: ProcessStartMode.detached,
        );
        return true;
      }
      await Process.start(
        installerPath,
        const <String>[],
        mode: ProcessStartMode.detached,
      );
      return true;
    }

    if (Platform.isMacOS) {
      await Process.start(
        'open',
        <String>[installerPath],
        mode: ProcessStartMode.detached,
      );
      return true;
    }

    return false;
  } catch (_) {
    return false;
  }
}
