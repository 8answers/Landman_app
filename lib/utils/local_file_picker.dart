import 'dart:typed_data';

import 'local_file_picker_stub.dart'
    if (dart.library.html) 'local_file_picker_web.dart'
    if (dart.library.io) 'local_file_picker_io.dart';

class PickedLocalFile {
  const PickedLocalFile({
    required this.name,
    required this.bytes,
    required this.sizeBytes,
    required this.mimeType,
  });

  final String name;
  final Uint8List bytes;
  final int sizeBytes;
  final String mimeType;
}

Future<PickedLocalFile?> pickSingleLocalFile({
  List<String>? allowedExtensions,
}) {
  return pickSingleLocalFileImpl(allowedExtensions: allowedExtensions);
}

Future<List<PickedLocalFile>> pickMultipleLocalFiles({
  List<String>? allowedExtensions,
}) {
  return pickMultipleLocalFilesImpl(allowedExtensions: allowedExtensions);
}
