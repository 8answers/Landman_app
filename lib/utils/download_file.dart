import 'dart:typed_data';

import 'download_file_stub.dart'
    if (dart.library.html) 'download_file_web.dart'
    if (dart.library.io) 'download_file_io.dart';

Future<bool> saveBytesToUserDevice({
  required Uint8List bytes,
  required String suggestedFileName,
  String mimeType = 'application/octet-stream',
}) {
  return saveBytesToUserDeviceImpl(
    bytes: bytes,
    suggestedFileName: suggestedFileName,
    mimeType: mimeType,
  );
}
