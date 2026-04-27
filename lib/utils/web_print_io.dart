import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
  final resolvedTitle = title.trim().isEmpty ? 'Image' : title.trim();
  final htmlDoc = _buildSingleImagePrintHtml(
    imageUrl: normalizedImageUrl,
    title: resolvedTitle,
  );
  await _writeAndOpenHtml(
    htmlDoc,
    filePrefix: 'landman_image_print_',
    fileNameBase: _sanitizeDocName(resolvedTitle),
  );
}

String _sanitizeDocName(String value) {
  final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9 _.-]'), '').trim();
  if (sanitized.isEmpty) {
    return 'Document';
  }
  return sanitized;
}

Future<void> printReportImages(
  List<Uint8List> pageImages, {
  Object? preOpenedWindow,
}) async {
  if (pageImages.isEmpty) {
    throw StateError('No report pages available for print.');
  }

  final usablePages = <Uint8List>[];
  for (final bytes in pageImages) {
    if (bytes.isNotEmpty) usablePages.add(bytes);
  }
  if (usablePages.isEmpty) {
    throw StateError('No valid report pages available for print.');
  }

  final copiedPages = usablePages
      .map((bytes) => Uint8List.fromList(bytes))
      .toList(growable: false);

  // Open as a separate browser print page and return quickly.
  unawaited(_openReportHtmlForManualPrint(copiedPages, docName: 'Report'));
  await Future<void>.delayed(const Duration(milliseconds: 120));
}

Future<void> _openReportHtmlForManualPrint(
  List<Uint8List> pages, {
  required String docName,
}) async {
  final safeDocName = _sanitizeDocName(docName);
  String htmlDoc;
  try {
    // Windows builds have shown sporadic isolate-init failures in report print.
    // Fall back to in-isolate HTML generation when isolate spawning fails.
    htmlDoc = await Isolate.run(
      () => _buildReportPrintHtml(pages: pages, docName: safeDocName),
    );
  } catch (_) {
    htmlDoc = _buildReportPrintHtml(pages: pages, docName: safeDocName);
  }
  await _writeAndOpenHtml(
    htmlDoc,
    filePrefix: 'landman_report_html_',
    fileNameBase: safeDocName,
  );
}

String _buildSingleImagePrintHtml({
  required String imageUrl,
  required String title,
}) {
  final safeTitle = const HtmlEscape(HtmlEscapeMode.element).convert(title);
  final safeImageUrl =
      const HtmlEscape(HtmlEscapeMode.attribute).convert(imageUrl.trim());
  return '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>$safeTitle</title>
    <style>
      @page { size: auto; margin: 0; }
      html, body {
        margin: 0;
        padding: 0;
        background: #ffffff;
        width: 100%;
        height: 100%;
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
    <img src="$safeImageUrl" alt="$safeTitle" />
    <script>
      window.onload = function () {
        setTimeout(function () { window.focus(); window.print(); }, 220);
      };
    </script>
  </body>
</html>
''';
}

String _buildReportPrintHtml({
  required List<Uint8List> pages,
  required String docName,
}) {
  final pagesMarkup = StringBuffer();
  for (var i = 0; i < pages.length; i++) {
    final base64Png = base64Encode(pages[i]);
    pagesMarkup.write('''
<section class="report-page">
  <img src="data:image/png;base64,$base64Png" alt="Report page ${i + 1}" />
</section>
''');
  }

  return '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>${const HtmlEscape(HtmlEscapeMode.element).convert(docName)}</title>
    <style>
      @page { size: A4 portrait; margin: 0; }
      html, body { margin: 0; padding: 0; background: #ffffff; }
      .report-page {
        display: block;
        width: 210mm;
        height: 297mm;
        page-break-after: always;
        break-after: page;
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
        setTimeout(function () { window.focus(); window.print(); }, 220);
      };
    </script>
  </body>
</html>
''';
}

Future<void> _writeAndOpenHtml(
  String htmlDoc, {
  required String filePrefix,
  required String fileNameBase,
}) async {
  final tempDir = await Directory.systemTemp.createTemp(filePrefix);
  final tempFile = File(
    '${tempDir.path}${Platform.pathSeparator}${fileNameBase}_${DateTime.now().millisecondsSinceEpoch}.html',
  );
  await tempFile.writeAsString(htmlDoc, flush: true);
  await _openInDefaultApp(tempFile.path);

  unawaited(
    Future<void>.delayed(const Duration(minutes: 30), () async {
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
  ProcessResult result = ProcessResult(
    0,
    1,
    '',
    'Failed to open print page',
  );
  if (Platform.isMacOS) {
    try {
      result = await Process.run('open', [targetPath]);
    } catch (error) {
      result = ProcessResult(0, 1, '', error.toString());
    }
  } else if (Platform.isWindows) {
    final fileUri = Uri.file(targetPath, windows: true).toString();
    try {
      result = await Process.run(
        'cmd',
        ['/c', 'start', '', fileUri],
        runInShell: true,
      );
    } catch (error) {
      result = ProcessResult(0, 1, '', error.toString());
    }
    if (result.exitCode != 0) {
      try {
        result = await Process.run(
          'cmd',
          ['/c', 'start', '', '"$targetPath"'],
          runInShell: true,
        );
      } catch (error) {
        result = ProcessResult(0, 1, '', error.toString());
      }
    }
  } else if (Platform.isLinux) {
    try {
      result = await Process.run('xdg-open', [targetPath]);
    } catch (error) {
      result = ProcessResult(0, 1, '', error.toString());
    }
  } else {
    throw UnsupportedError('Opening files is not supported on this platform.');
  }

  if (result.exitCode != 0) {
    final stderrText = (result.stderr ?? '').toString().trim();
    final stdoutText = (result.stdout ?? '').toString().trim();
    throw StateError(
      stderrText.isNotEmpty
          ? stderrText
          : (stdoutText.isNotEmpty ? stdoutText : 'Failed to open print page'),
    );
  }
}
