import 'dart:io';
import 'dart:typed_data';

import 'offline_upload_blob_store.dart';

class _IoOfflineUploadBlobStore implements OfflineUploadBlobStore {
  static const String _dirName = '.landman_offline_upload_blobs';

  Future<Directory> _ensureDirectory() async {
    final home = Platform.environment['HOME']?.trim() ??
        Platform.environment['USERPROFILE']?.trim() ??
        '';
    final basePath = home.isNotEmpty ? home : Directory.systemTemp.path;
    final dir = Directory('$basePath${Platform.pathSeparator}$_dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _sanitizeBlobKey(String blobKey) {
    return blobKey.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
  }

  Future<File> _fileForKey(String blobKey) async {
    final dir = await _ensureDirectory();
    final safe = _sanitizeBlobKey(blobKey);
    return File('${dir.path}${Platform.pathSeparator}$safe.bin');
  }

  @override
  Future<void> writeBytes(String blobKey, Uint8List bytes) async {
    final file = await _fileForKey(blobKey);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> readBytes(String blobKey) async {
    final file = await _fileForKey(blobKey);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> deleteBytes(String blobKey) async {
    final file = await _fileForKey(blobKey);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

OfflineUploadBlobStore createOfflineUploadBlobStoreImpl() =>
    _IoOfflineUploadBlobStore();
