import 'dart:typed_data';

Future<bool> saveBytesToUserDeviceImpl({
  required Uint8List bytes,
  required String suggestedFileName,
  String mimeType = 'application/octet-stream',
}) async {
  throw UnsupportedError('File download is not supported on this platform.');
}
