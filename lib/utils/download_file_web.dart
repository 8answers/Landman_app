import 'dart:typed_data';

import 'package:universal_html/html.dart' as html;

Future<bool> saveBytesToUserDeviceImpl({
  required Uint8List bytes,
  required String suggestedFileName,
  String mimeType = 'application/octet-stream',
}) async {
  if (bytes.isEmpty) return false;
  final name =
      suggestedFileName.trim().isEmpty ? 'download' : suggestedFileName.trim();
  final blob = html.Blob([bytes], mimeType);
  final objectUrl = html.Url.createObjectUrlFromBlob(blob);
  try {
    final anchor = html.AnchorElement(href: objectUrl)
      ..download = name
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    return true;
  } finally {
    html.Url.revokeObjectUrl(objectUrl);
  }
}
