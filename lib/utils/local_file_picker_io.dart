import 'package:file_selector/file_selector.dart';

import 'local_file_picker.dart';

Future<PickedLocalFile?> pickSingleLocalFileImpl({
  List<String>? allowedExtensions,
}) async {
  final groups = _buildTypeGroups(allowedExtensions);
  final XFile? selected = groups.isEmpty
      ? await openFile()
      : await openFile(acceptedTypeGroups: groups);
  if (selected == null) return null;
  return _toPickedLocalFile(selected);
}

Future<List<PickedLocalFile>> pickMultipleLocalFilesImpl({
  List<String>? allowedExtensions,
}) async {
  final groups = _buildTypeGroups(allowedExtensions);
  final List<XFile> selected = groups.isEmpty
      ? await openFiles()
      : await openFiles(acceptedTypeGroups: groups);
  if (selected.isEmpty) return const <PickedLocalFile>[];
  final resolved = <PickedLocalFile>[];
  for (final file in selected) {
    resolved.add(await _toPickedLocalFile(file));
  }
  return resolved;
}

List<XTypeGroup> _buildTypeGroups(List<String>? allowedExtensions) {
  final normalizedExtensions = _normalizeExtensions(allowedExtensions);
  if (normalizedExtensions.isEmpty) return const <XTypeGroup>[];
  return <XTypeGroup>[
    XTypeGroup(
      label: 'Files',
      extensions: normalizedExtensions,
    ),
  ];
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

Future<PickedLocalFile> _toPickedLocalFile(XFile file) async {
  final bytes = await file.readAsBytes();
  final name =
      file.name.trim().isNotEmpty ? file.name.trim() : _basename(file.path);
  return PickedLocalFile(
    name: name,
    bytes: bytes,
    sizeBytes: bytes.length,
    mimeType: _mimeTypeForFileName(name),
  );
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/').trim();
  if (normalized.isEmpty) return '';
  final index = normalized.lastIndexOf('/');
  if (index < 0 || index >= normalized.length - 1) return normalized;
  return normalized.substring(index + 1);
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
