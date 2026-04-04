import 'dart:async';
import 'dart:typed_data';

import 'package:universal_html/html.dart' as html;

import 'local_file_picker.dart';

Future<PickedLocalFile?> pickSingleLocalFileImpl({
  List<String>? allowedExtensions,
}) async {
  final files = await _pickFilesInternal(
    allowMultiple: false,
    allowedExtensions: allowedExtensions,
  );
  if (files.isEmpty) return null;
  return files.first;
}

Future<List<PickedLocalFile>> pickMultipleLocalFilesImpl({
  List<String>? allowedExtensions,
}) {
  return _pickFilesInternal(
    allowMultiple: true,
    allowedExtensions: allowedExtensions,
  );
}

Future<List<PickedLocalFile>> _pickFilesInternal({
  required bool allowMultiple,
  List<String>? allowedExtensions,
}) async {
  final uploadInput = html.FileUploadInputElement();
  uploadInput.multiple = allowMultiple;

  final normalizedExtensions = _normalizeExtensions(allowedExtensions);
  if (normalizedExtensions.isNotEmpty) {
    uploadInput.accept = normalizedExtensions.map((e) => '.$e').join(',');
  }

  final fileSelectionCompleter = Completer<List<html.File>>();
  StreamSubscription<html.Event>? changeSub;
  StreamSubscription<html.Event>? inputSub;
  StreamSubscription<html.Event>? blurSub;
  StreamSubscription<html.Event>? focusSub;
  Timer? fallbackCancelTimer;
  Timer? focusResolveTimer;
  var windowLostFocus = false;

  void resolveFromPickerState() {
    if (fileSelectionCompleter.isCompleted) return;
    final picked = uploadInput.files;
    if (picked == null || picked.isEmpty) {
      fileSelectionCompleter.complete(const <html.File>[]);
      return;
    }
    fileSelectionCompleter.complete(picked.toList(growable: false));
  }

  changeSub = uploadInput.onChange.listen((_) => resolveFromPickerState());
  inputSub = uploadInput.onInput.listen((_) => resolveFromPickerState());
  blurSub = html.window.onBlur.listen((_) {
    windowLostFocus = true;
  });
  focusSub = html.window.onFocus.listen((_) {
    if (!windowLostFocus) return;
    focusResolveTimer?.cancel();
    focusResolveTimer = Timer(const Duration(milliseconds: 350), () {
      resolveFromPickerState();
    });
  });
  fallbackCancelTimer = Timer(const Duration(seconds: 12), () {
    resolveFromPickerState();
  });

  html.document.body?.append(uploadInput);
  uploadInput.click();
  final pickedFiles = await fileSelectionCompleter.future;
  await changeSub.cancel();
  await inputSub.cancel();
  await blurSub.cancel();
  await focusSub.cancel();
  fallbackCancelTimer.cancel();
  focusResolveTimer?.cancel();
  uploadInput.remove();

  if (pickedFiles.isEmpty) return const <PickedLocalFile>[];

  final resolved = <PickedLocalFile>[];
  for (final file in pickedFiles) {
    final bytes = await _readFileBytes(file);
    if (bytes == null || bytes.isEmpty) continue;
    final fileName = file.name.trim();
    if (fileName.isEmpty) continue;
    final mimeType = file.type.trim().isNotEmpty
        ? file.type.trim()
        : _mimeTypeForFileName(fileName);
    resolved.add(
      PickedLocalFile(
        name: fileName,
        bytes: bytes,
        sizeBytes: file.size,
        mimeType: mimeType,
      ),
    );
  }

  return resolved;
}

List<String> _normalizeExtensions(List<String>? allowedExtensions) {
  if (allowedExtensions == null || allowedExtensions.isEmpty) {
    return const <String>[];
  }
  return allowedExtensions
      .map((raw) => raw.trim().replaceFirst(RegExp(r'^\.'), '').toLowerCase())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList(growable: false);
}

Future<Uint8List?> _readFileBytes(html.File file) async {
  final reader = html.FileReader();
  reader.readAsArrayBuffer(file);
  await reader.onLoadEnd.first;
  final result = reader.result;
  if (result == null) return null;
  if (result is Uint8List) return result;
  if (result is ByteBuffer) return Uint8List.view(result);
  if (result is List<int>) return Uint8List.fromList(result);
  if (result is List) {
    final ints = result.whereType<num>().map((e) => e.toInt()).toList();
    return Uint8List.fromList(ints);
  }
  return null;
}

String _mimeTypeForFileName(String fileName) {
  final lowerName = fileName.trim().toLowerCase();
  final dotIndex = lowerName.lastIndexOf('.');
  final extension = dotIndex >= 0 ? lowerName.substring(dotIndex + 1) : '';
  const contentTypeMap = <String, String>{
    'csv': 'text/csv',
    'doc': 'application/msword',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'gif': 'image/gif',
    'heic': 'image/heic',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'svg': 'image/svg+xml',
    'webp': 'image/webp',
    'mp4': 'video/mp4',
    'pdf': 'application/pdf',
    'dwg': 'application/acad',
    'zip': 'application/zip',
    'txt': 'text/plain',
    'dxf': 'application/dxf',
  };
  return contentTypeMap[extension] ?? 'application/octet-stream';
}
