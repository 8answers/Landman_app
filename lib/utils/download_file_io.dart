import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

Future<bool> saveBytesToUserDeviceImpl({
  required Uint8List bytes,
  required String suggestedFileName,
  String mimeType = 'application/octet-stream',
}) async {
  if (bytes.isEmpty) return false;
  final defaultName =
      suggestedFileName.trim().isEmpty ? 'download' : suggestedFileName.trim();
  final location = await getSaveLocation(suggestedName: defaultName);
  if (location == null || location.path.trim().isEmpty) return false;

  final outFile = File(location.path);
  await outFile.parent.create(recursive: true);
  await outFile.writeAsBytes(bytes, flush: true);
  return true;
}
