import 'dart:typed_data';

import 'offline_upload_blob_store.dart';

class _NoopOfflineUploadBlobStore implements OfflineUploadBlobStore {
  @override
  Future<void> writeBytes(String blobKey, Uint8List bytes) async {}

  @override
  Future<Uint8List?> readBytes(String blobKey) async => null;

  @override
  Future<void> deleteBytes(String blobKey) async {}
}

OfflineUploadBlobStore createOfflineUploadBlobStoreImpl() =>
    _NoopOfflineUploadBlobStore();
