import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

html.DivElement? _activePrintRoot;
html.StyleElement? _activePrintStyle;
List<String> _activeBlobUrls = <String>[];

Object? preOpenPrintWindow() {
  try {
    return html.window.open('', '_blank', 'width=1200,height=900');
  } catch (_) {
    return null;
  }
}

void closePrintWindow(Object? windowHandle) {
  if (windowHandle is html.WindowBase) {
    try {
      windowHandle.close();
    } catch (_) {}
  }
}

Future<void> printSingleImage({
  required String imageUrl,
  required String title,
  Object? preOpenedWindow,
}) async {
  final normalizedImageUrl = imageUrl.trim();
  if (normalizedImageUrl.isEmpty) {
    throw StateError('No image URL available for print.');
  }

  final popupWindow =
      preOpenedWindow is html.WindowBase ? preOpenedWindow : null;
  final safeTitle = htmlEscape.convert(title.trim().isEmpty ? 'Image' : title);
  final safeImageUrl =
      const HtmlEscape(HtmlEscapeMode.attribute).convert(normalizedImageUrl);
  final printDocument = '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>$safeTitle</title>
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
    <img src="$safeImageUrl" alt="$safeTitle" onload="setTimeout(function(){ window.focus(); window.print(); }, 120);" />
  </body>
</html>
''';
  final htmlBlob = html.Blob([printDocument], 'text/html');
  final htmlBlobUrl = html.Url.createObjectUrlFromBlob(htmlBlob);
  if (popupWindow != null) {
    popupWindow.location.href = htmlBlobUrl;
  } else {
    html.window.open(htmlBlobUrl, '_blank', 'width=1200,height=900');
  }
  Future<void>.delayed(const Duration(minutes: 2), () {
    html.Url.revokeObjectUrl(htmlBlobUrl);
  });
}

Future<void> printReportImages(
  List<Uint8List> pageImages, {
  Object? preOpenedWindow,
}) async {
  if (pageImages.isEmpty) {
    throw StateError('No report pages available for print.');
  }

  final popupWindow =
      preOpenedWindow is html.WindowBase ? preOpenedWindow : null;
  if (popupWindow != null) {
    try {
      final pagesMarkup = StringBuffer();
      for (var i = 0; i < pageImages.length; i++) {
        final base64Png = base64Encode(pageImages[i]);
        pagesMarkup.write('''
<section class="report-page">
  <img src="data:image/png;base64,$base64Png" alt="Report page ${i + 1}" />
</section>
''');
      }

      final popupDoc = '''
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
        }, 160);
      };
      window.onafterprint = function () {
        setTimeout(function () { window.close(); }, 120);
      };
    </script>
  </body>
</html>
''';

      final popupBlob = html.Blob([popupDoc], 'text/html');
      final popupBlobUrl = html.Url.createObjectUrlFromBlob(popupBlob);
      popupWindow.location.href = popupBlobUrl;
      Future<void>.delayed(const Duration(minutes: 2), () {
        html.Url.revokeObjectUrl(popupBlobUrl);
      });
      return;
    } catch (_) {
      closePrintWindow(popupWindow);
      // Fallback to in-page print flow below.
    }
  }

  _cleanupStalePrintDom();
  _cleanupActivePrintArtifacts();

  final body = html.document.body;
  if (body == null) {
    throw StateError('Unable to access document body for print.');
  }

  final styleElement = html.StyleElement()
    ..setAttribute('data-report-print-style', 'true')
    ..text = '''
@page {
  size: A4 portrait;
  margin: 0;
}

#report-print-root {
  display: block;
  position: fixed;
  left: -200vw;
  top: 0;
  visibility: hidden;
}

@media print {
  html, body {
    position: static !important;
    overflow: visible !important;
    height: auto !important;
    width: auto !important;
    max-height: none !important;
    max-width: none !important;
    margin: 0 !important;
    padding: 0 !important;
    transform: none !important;
  }

  body > *:not(#report-print-root):not(style[data-report-print-style]) {
    display: none !important;
  }

  #report-print-root {
    display: block !important;
    position: static !important;
    left: auto !important;
    top: auto !important;
    visibility: visible !important;
    margin: 0 !important;
    padding: 0 !important;
    background: #fff !important;
  }

  #report-print-root .report-page {
    display: block !important;
    box-sizing: border-box !important;
    width: 210mm !important;
    height: 297mm !important;
    min-height: 297mm !important;
    overflow: hidden !important;
    page-break-after: always !important;
    break-after: page !important;
    page-break-inside: avoid !important;
    break-inside: avoid !important;
  }

  #report-print-root .report-page:last-child {
    page-break-after: auto !important;
    break-after: auto !important;
  }

  #report-print-root .report-page img {
    display: block !important;
    width: 100% !important;
    height: 100% !important;
    object-fit: fill !important;
  }
}
''';

  final printRoot = html.DivElement()..id = 'report-print-root';
  final blobUrls = <String>[];
  final images = <html.ImageElement>[];

  for (final bytes in pageImages) {
    final blob = html.Blob([bytes], 'image/png');
    final blobUrl = html.Url.createObjectUrlFromBlob(blob);
    blobUrls.add(blobUrl);

    final image = html.ImageElement()
      ..src = blobUrl
      ..alt = 'Report page';
    images.add(image);

    final page = html.Element.section()..classes.add('report-page');
    page.append(image);
    printRoot.append(page);
  }

  html.document.head?.append(styleElement);
  body.append(printRoot);
  _activePrintStyle = styleElement;
  _activePrintRoot = printRoot;
  _activeBlobUrls = blobUrls;

  var printTriggered = false;
  try {
    for (var i = 0; i < 80; i++) {
      final allDecoded = images
          .every((img) => (img.complete == true) && (img.naturalWidth > 0));
      if (allDecoded) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await Future<void>.delayed(const Duration(milliseconds: 900));
    html.window.print();
    printTriggered = true;
  } finally {
    if (!printTriggered) {
      _cleanupActivePrintArtifacts();
    }
  }
}

void _cleanupStalePrintDom() {
  final staleRoots = html.document.querySelectorAll('#report-print-root');
  for (final root in staleRoots) {
    root.remove();
  }

  final staleStyles =
      html.document.querySelectorAll('style[data-report-print-style]');
  for (final style in staleStyles) {
    style.remove();
  }
}

void _cleanupActivePrintArtifacts() {
  _activePrintRoot?.remove();
  _activePrintStyle?.remove();
  for (final url in _activeBlobUrls) {
    html.Url.revokeObjectUrl(url);
  }
  _activePrintRoot = null;
  _activePrintStyle = null;
  _activeBlobUrls = <String>[];
}
