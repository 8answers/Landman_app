import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'app_update_service.dart';

Future<bool> tryRunInstallerImpl(AppUpdateInfo updateInfo) async {
  final rawUrl = (updateInfo.downloadUrl ?? '').trim();
  if (rawUrl.isEmpty) return false;

  final uri = Uri.tryParse(rawUrl);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;

  final sourceName = (updateInfo.assetName ?? '').trim().isNotEmpty
      ? (updateInfo.assetName ?? '').trim()
      : uri.path.trim();
  final extension = _assetExtension(
    name: sourceName,
    path: uri.path,
  );
  if (!_isSupportedInstallerAsset(extension, sourceName)) return false;

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

    if (extension == '.zip') {
      final extractedRoot = await _extractZipToTempDirectory(
        zipBytes: bytes,
        sourceAssetName: targetName,
      );
      if (extractedRoot == null) return false;

      final extractedInstaller = await _findBestInstallerInDirectory(
        extractedRoot,
      );
      if (extractedInstaller != null) {
        final extractedExtension = _assetExtension(
          name: extractedInstaller.path,
          path: extractedInstaller.path,
        );
        if (extractedExtension.isNotEmpty &&
            _isSupportedInstallerAsset(
              extractedExtension,
              extractedInstaller.path,
            )) {
          return await _launchInstaller(
            installerPath: extractedInstaller.path,
            extension: extractedExtension,
          );
        }
      }

      if (Platform.isWindows) {
        final portableExe = await _findBestPortableWindowsExe(extractedRoot);
        if (portableExe == null) return false;
        return await _launchWindowsPortableSelfUpdate(
          sourceExecutablePath: portableExe.path,
        );
      }

      if (Platform.isMacOS) {
        final appBundle = await _findBestMacAppBundleInDirectory(extractedRoot);
        if (appBundle == null) return false;
        return await _launchMacAppBundleSelfUpdate(
          sourceAppBundlePath: appBundle.path,
        );
      }

      return false;
    }

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
  if (source.endsWith('.zip')) return '.zip';
  return '';
}

bool _isSupportedInstallerAsset(String extension, String sourceName) {
  if (extension.isEmpty) return false;
  final normalizedSource = sourceName.trim().toLowerCase();
  final looksLikeSetupInstaller = normalizedSource.contains('setup') ||
      normalizedSource.contains('installer') ||
      normalizedSource.contains('install');

  if (Platform.isWindows) {
    if (extension == '.msi') return true;
    if (extension == '.exe') return looksLikeSetupInstaller;
    if (extension == '.zip') return true;
    return false;
  }
  if (Platform.isMacOS) {
    return extension == '.pkg' || extension == '.dmg' || extension == '.zip';
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
      if (extension == '.dmg') {
        return await _launchMacDmgSelfUpdate(dmgPath: installerPath);
      }
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

Future<bool> _launchMacDmgSelfUpdate({
  required String dmgPath,
}) async {
  if (!Platform.isMacOS) return false;
  final appBundlePath = _resolveCurrentMacAppBundlePath();
  if (appBundlePath.isEmpty) {
    // Fallback to regular behavior when app bundle path is unavailable.
    await Process.start(
      'open',
      <String>[dmgPath],
      mode: ProcessStartMode.detached,
    );
    return true;
  }

  try {
    final scriptPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}8answers_apply_update_${DateTime.now().millisecondsSinceEpoch}.sh';
    final pid = pidOrZero();
    final escapedDmg = _escapeSingleQuotedShell(dmgPath);
    final escapedAppDst = _escapeSingleQuotedShell(appBundlePath);
    final script = StringBuffer()
      ..writeln('#!/bin/bash')
      ..writeln('set -e')
      ..writeln("DMG_PATH='$escapedDmg'")
      ..writeln("APP_DST='$escapedAppDst'")
      ..writeln('APP_PID=$pid')
      ..writeln('MOUNT_POINT="/tmp/8answers_update_mount_\${APP_PID}_\$\$"')
      ..writeln('while kill -0 "\$APP_PID" 2>/dev/null; do sleep 1; done')
      ..writeln('mkdir -p "\$MOUNT_POINT"')
      ..writeln(
          '/usr/bin/hdiutil attach "\$DMG_PATH" -nobrowse -quiet -mountpoint "\$MOUNT_POINT"')
      ..writeln(
          'APP_SRC="\$(/usr/bin/find "\$MOUNT_POINT" -maxdepth 2 -name "*.app" -print -quit)"')
      ..writeln('if [ -z "\$APP_SRC" ]; then')
      ..writeln('  /usr/bin/hdiutil detach "\$MOUNT_POINT" -quiet || true')
      ..writeln('  exit 1')
      ..writeln('fi')
      ..writeln(
          'if ! /usr/bin/rsync -a --delete "\$APP_SRC/" "\$APP_DST/"; then')
      ..writeln('  /bin/cp -R "\$APP_SRC" "\$(dirname "\$APP_DST")/"')
      ..writeln('fi')
      ..writeln('/usr/bin/hdiutil detach "\$MOUNT_POINT" -quiet || true')
      ..writeln('/usr/bin/open "\$APP_DST"')
      ..writeln('/bin/rm -f "\$DMG_PATH"')
      ..writeln('/bin/rm -f "\$0"');

    final scriptFile = File(scriptPath);
    await scriptFile.writeAsString(script.toString(), flush: true);
    await Process.run('chmod', <String>['+x', scriptPath]);
    await Process.start(
      '/bin/bash',
      <String>[scriptPath],
      mode: ProcessStartMode.detached,
    );
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> _launchMacAppBundleSelfUpdate({
  required String sourceAppBundlePath,
}) async {
  if (!Platform.isMacOS) return false;
  final appBundlePath = _resolveCurrentMacAppBundlePath();
  if (appBundlePath.isEmpty) return false;

  try {
    final scriptPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}8answers_apply_update_${DateTime.now().millisecondsSinceEpoch}.sh';
    final pid = pidOrZero();
    final escapedSourceApp = _escapeSingleQuotedShell(sourceAppBundlePath);
    final escapedAppDst = _escapeSingleQuotedShell(appBundlePath);
    final script = StringBuffer()
      ..writeln('#!/bin/bash')
      ..writeln('set -e')
      ..writeln("APP_SRC='$escapedSourceApp'")
      ..writeln("APP_DST='$escapedAppDst'")
      ..writeln('APP_PID=$pid')
      ..writeln('while kill -0 "\$APP_PID" 2>/dev/null; do sleep 1; done')
      ..writeln(
          'if ! /usr/bin/rsync -a --delete "\$APP_SRC/" "\$APP_DST/"; then')
      ..writeln('  /bin/cp -R "\$APP_SRC" "\$(dirname "\$APP_DST")/"')
      ..writeln('fi')
      ..writeln('/usr/bin/open "\$APP_DST"')
      ..writeln('/bin/rm -f "\$0"');

    final scriptFile = File(scriptPath);
    await scriptFile.writeAsString(script.toString(), flush: true);
    await Process.run('chmod', <String>['+x', scriptPath]);
    await Process.start(
      '/bin/bash',
      <String>[scriptPath],
      mode: ProcessStartMode.detached,
    );
    return true;
  } catch (_) {
    return false;
  }
}

String _resolveCurrentMacAppBundlePath() {
  if (!Platform.isMacOS) return '';
  try {
    var current = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8; i++) {
      final path = current.path;
      if (path.toLowerCase().endsWith('.app')) {
        return path;
      }
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
  } catch (_) {
    return '';
  }
  return '';
}

Future<Directory?> _extractZipToTempDirectory({
  required Uint8List zipBytes,
  required String sourceAssetName,
}) async {
  final safeAssetName = sourceAssetName
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), '_')
      .trim();
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final extractionRoot = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    '8answers_update_extract_${timestamp}_$safeAssetName',
  );
  try {
    await extractionRoot.create(recursive: true);
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    for (final entry in archive) {
      final relative = _safeArchiveRelativePath(entry.name);
      if (relative.isEmpty) continue;
      final outputPath =
          '${extractionRoot.path}${Platform.pathSeparator}$relative';
      if (entry.isFile) {
        final outputFile = File(outputPath);
        await outputFile.parent.create(recursive: true);
        final content = entry.content;
        if (content is List<int>) {
          await outputFile.writeAsBytes(content, flush: true);
        } else {
          await outputFile.writeAsBytes(<int>[], flush: true);
        }
      } else {
        await Directory(outputPath).create(recursive: true);
      }
    }
    return extractionRoot;
  } catch (_) {
    return null;
  }
}

String _safeArchiveRelativePath(String rawPath) {
  final normalized = rawPath
      .replaceAll('\\', '/')
      .split('/')
      .where((segment) => segment.trim().isNotEmpty && segment != '.')
      .toList(growable: false);
  if (normalized.isEmpty) return '';
  if (normalized.any((segment) => segment == '..')) return '';
  return normalized.join(Platform.pathSeparator);
}

Future<File?> _findBestPortableWindowsExe(Directory directory) async {
  if (!Platform.isWindows) return null;
  final currentExeName =
      _fileNameFromPath(Platform.resolvedExecutable).toLowerCase().trim();
  final entries = await directory
      .list(recursive: true, followLinks: false)
      .where((entity) =>
          entity is File && entity.path.toLowerCase().endsWith('.exe'))
      .cast<File>()
      .toList();
  if (entries.isEmpty) return null;

  int score(File file) {
    final lowerPath = file.path.toLowerCase();
    final lowerName = _fileNameFromPath(file.path).toLowerCase();
    if (lowerName == currentExeName) return 200;
    if (lowerName.contains('setup') || lowerName.contains('installer')) {
      return 20;
    }
    if (lowerName.contains('uninstall')) return 0;
    if (lowerPath.contains(r'\flutter\ephemeral\')) return 0;
    return 80;
  }

  File? best;
  var bestScore = 0;
  for (final entry in entries) {
    final candidateScore = score(entry);
    if (candidateScore > bestScore) {
      best = entry;
      bestScore = candidateScore;
    }
  }
  return bestScore > 0 ? best : null;
}

Future<bool> _launchWindowsPortableSelfUpdate({
  required String sourceExecutablePath,
}) async {
  if (!Platform.isWindows) return false;
  try {
    final currentExe = File(Platform.resolvedExecutable);
    final currentExeName = _fileNameFromPath(currentExe.path);
    final currentDir = currentExe.parent.path;
    final sourceDir = File(sourceExecutablePath).parent.path;
    final pid = pidOrZero();
    if (currentExeName.isEmpty || currentDir.isEmpty || sourceDir.isEmpty) {
      return false;
    }

    final scriptPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}8answers_apply_update_${DateTime.now().millisecondsSinceEpoch}.cmd';
    final script = StringBuffer()
      ..writeln('@echo off')
      ..writeln('setlocal')
      ..writeln('set "SRC=${_escapeCmdValue(sourceDir)}"')
      ..writeln('set "DST=${_escapeCmdValue(currentDir)}"')
      ..writeln('set "EXE=${_escapeCmdValue(currentExeName)}"')
      ..writeln('set "APPPID=$pid"')
      ..writeln(':waitloop')
      ..writeln('tasklist /FI "PID eq %APPPID%" | find "%APPPID%" >nul')
      ..writeln('if not errorlevel 1 (')
      ..writeln('  timeout /t 1 /nobreak >nul')
      ..writeln('  goto waitloop')
      ..writeln(')')
      ..writeln(
          'robocopy "%SRC%" "%DST%" /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP >nul')
      ..writeln('start "" "%DST%\\%EXE%"')
      ..writeln('del "%~f0"');

    final scriptFile = File(scriptPath);
    await scriptFile.writeAsString(script.toString(), flush: true);

    await Process.start(
      'cmd',
      <String>['/c', scriptPath],
      mode: ProcessStartMode.detached,
    );
    return true;
  } catch (_) {
    return false;
  }
}

int pidOrZero() {
  try {
    return pid;
  } catch (_) {
    return 0;
  }
}

String _escapeCmdValue(String value) {
  return value.replaceAll('"', '""');
}

String _escapeSingleQuotedShell(String value) {
  return value.replaceAll("'", "'\"'\"'");
}

String _fileNameFromPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final idx = normalized.lastIndexOf('/');
  if (idx < 0) return normalized;
  if (idx >= normalized.length - 1) return '';
  return normalized.substring(idx + 1);
}

Future<FileSystemEntity?> _findBestInstallerInDirectory(
  Directory directory,
) async {
  final entries =
      await directory.list(recursive: true, followLinks: false).toList();
  if (entries.isEmpty) return null;

  int scoreEntity(FileSystemEntity entity) {
    final lowerPath = entity.path.toLowerCase();
    if (Platform.isWindows) {
      if (lowerPath.endsWith('.msi')) return 120;
      if (lowerPath.endsWith('.exe') &&
          (lowerPath.contains('setup') ||
              lowerPath.contains('installer') ||
              lowerPath.contains('install'))) {
        return 110;
      }
      return 0;
    }

    if (Platform.isMacOS) {
      if (lowerPath.endsWith('.pkg')) return 120;
      if (lowerPath.endsWith('.dmg')) return 110;
      return 0;
    }
    return 0;
  }

  FileSystemEntity? best;
  var bestScore = 0;
  for (final entry in entries) {
    final score = scoreEntity(entry);
    if (score > bestScore) {
      best = entry;
      bestScore = score;
    }
  }

  return bestScore > 0 ? best : null;
}

Future<Directory?> _findBestMacAppBundleInDirectory(
  Directory directory,
) async {
  if (!Platform.isMacOS) return null;
  final entries =
      await directory.list(recursive: true, followLinks: false).toList();
  if (entries.isEmpty) return null;

  int scoreEntity(Directory entity) {
    final lowerPath = entity.path.toLowerCase();
    if (!lowerPath.endsWith('.app')) return 0;
    if (lowerPath.contains('__macosx')) return 0;
    final lowerName = _fileNameFromPath(lowerPath);
    if (lowerName == '8answers.app') return 200;
    return 120;
  }

  Directory? best;
  var bestScore = 0;
  for (final entry in entries) {
    if (entry is! Directory) continue;
    final score = scoreEntity(entry);
    if (score > bestScore) {
      best = entry;
      bestScore = score;
    }
  }

  return bestScore > 0 ? best : null;
}
