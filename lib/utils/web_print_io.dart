import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Object? preOpenPrintWindow() {
  return null;
}

void closePrintWindow(Object? windowHandle) {}

Future<void> printSingleImage({
  required String imageUrl,
  required String title,
  Object? preOpenedWindow,
}) async {
  final normalizedImageUrl = imageUrl.trim();
  if (normalizedImageUrl.isEmpty) {
    throw StateError('No image URL available for print.');
  }
  final escapedTitle = const HtmlEscape(HtmlEscapeMode.element)
      .convert(title.trim().isEmpty ? 'Image' : title.trim());
  final escapedImageUrl =
      const HtmlEscape(HtmlEscapeMode.attribute).convert(normalizedImageUrl);
  final htmlDoc = '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>$escapedTitle</title>
    <style>
      html, body {
        margin: 0;
        padding: 0;
        width: 100%;
        height: 100%;
        background: #ffffff;
      }
      body {
        display: flex;
        align-items: center;
        justify-content: center;
      }
      img {
        max-width: 100vw;
        max-height: 100vh;
        object-fit: contain;
      }
    </style>
  </head>
  <body>
    <img src="$escapedImageUrl" alt="$escapedTitle" onload="setTimeout(function(){ window.focus(); window.print(); }, 220);" />
  </body>
</html>
''';

  final tempDir = await Directory.systemTemp.createTemp('landman_image_print_');
  final tempFile = File(
    '${tempDir.path}${Platform.pathSeparator}image_print_${DateTime.now().millisecondsSinceEpoch}.html',
  );
  await tempFile.writeAsString(htmlDoc, flush: true);
  await _openInDefaultApp(tempFile.path);

  unawaited(
    Future<void>.delayed(const Duration(minutes: 10), () async {
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }),
  );
}

Future<void> printReportImages(
  List<Uint8List> pageImages, {
  Object? preOpenedWindow,
}) async {
  if (pageImages.isEmpty) {
    throw StateError('No report pages available for print.');
  }

  final pagesMarkup = StringBuffer();
  for (var i = 0; i < pageImages.length; i++) {
    final base64Png = base64Encode(pageImages[i]);
    pagesMarkup.write('''
<section class="report-page">
  <img src="data:image/png;base64,$base64Png" alt="Report page ${i + 1}" />
</section>
''');
  }

  final printDocument = '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>Report Print</title>
    <style>
      @page {
        size: A4 portrait;
        margin: 0;
      }
      html, body {
        margin: 0;
        padding: 0;
        background: #ffffff;
      }
      .report-page {
        display: block;
        box-sizing: border-box;
        width: 210mm;
        height: 297mm;
        min-height: 297mm;
        overflow: hidden;
        page-break-after: always;
        break-after: page;
        page-break-inside: avoid;
        break-inside: avoid;
      }
      .report-page:last-child {
        page-break-after: auto;
        break-after: auto;
      }
      .report-page img {
        display: block;
        width: 100%;
        height: 100%;
        object-fit: fill;
      }
    </style>
  </head>
  <body>
    ${pagesMarkup.toString()}
    <script>
      window.onload = function () {
        setTimeout(function () {
          window.focus();
          window.print();
        }, 220);
      };
    </script>
  </body>
</html>
''';

  final tempDir =
      await Directory.systemTemp.createTemp('landman_report_print_');
  final tempFile = File(
    '${tempDir.path}${Platform.pathSeparator}report_print_${DateTime.now().millisecondsSinceEpoch}.html',
  );
  await tempFile.writeAsString(printDocument, flush: true);

  await _openInDefaultApp(tempFile.path);

  unawaited(
    Future<void>.delayed(const Duration(minutes: 10), () async {
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }),
  );
}

Future<void> _openInDefaultApp(String targetPath) async {
  if (Platform.isWindows) {
    final fileUri = Uri.file(targetPath, windows: true).toString();
    final attemptErrors = <String>[];

    final openedViaCmd = await _tryOpenInDefaultApp(
      executable: 'cmd',
      arguments: ['/c', 'start', '', '"$targetPath"'],
      runInShell: true,
      errorCollector: attemptErrors,
    );
    if (openedViaCmd) return;

    final openedViaCmdUri = await _tryOpenInDefaultApp(
      executable: 'cmd',
      arguments: ['/c', 'start', '', fileUri],
      runInShell: true,
      errorCollector: attemptErrors,
    );
    if (openedViaCmdUri) return;

    final openedViaExplorer = await _tryOpenInDefaultApp(
      executable: 'explorer',
      arguments: [targetPath],
      errorCollector: attemptErrors,
    );
    if (openedViaExplorer) return;

    final openedViaRundll32 = await _tryOpenInDefaultApp(
      executable: 'rundll32',
      arguments: ['url.dll,FileProtocolHandler', fileUri],
      errorCollector: attemptErrors,
    );
    if (openedViaRundll32) return;

    throw StateError(
      'Could not open report print preview: ${attemptErrors.join(' | ')}',
    );
  }

  ProcessResult result;
  if (Platform.isMacOS) {
    result = await Process.run('open', [targetPath]);
  } else if (Platform.isLinux) {
    result = await Process.run('xdg-open', [targetPath]);
  } else {
    throw UnsupportedError('Report print is not supported on this platform.');
  }

  if (result.exitCode != 0) {
    throw StateError(
      'Could not open report print preview: '
      '${_formatProcessLaunchError(result)}',
    );
  }
}

Future<bool> _tryOpenInDefaultApp({
  required String executable,
  required List<String> arguments,
  required List<String> errorCollector,
  bool runInShell = false,
}) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      runInShell: runInShell,
    );
    if (result.exitCode == 0) return true;
    errorCollector.add(
        '$executable ${arguments.join(' ')} -> ${_formatProcessLaunchError(result)}');
    return false;
  } catch (error) {
    errorCollector.add('$executable ${arguments.join(' ')} -> $error');
    return false;
  }
}

String _formatProcessLaunchError(ProcessResult result) {
  final stderrText = (result.stderr ?? '').toString().trim();
  final stdoutText = (result.stdout ?? '').toString().trim();
  if (stderrText.isNotEmpty) return stderrText;
  if (stdoutText.isNotEmpty) return stdoutText;
  return 'exit ${result.exitCode}';
}
