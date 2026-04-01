import 'dart:typed_data';

import 'offline_upload_blob_store_stub.dart'
    if (dart.library.html) 'offline_upload_blob_store_web.dart'
    if (dart.library.io) 'offline_upload_blob_store_io.dart';

abstract class OfflineUploadBlobStore {
  Future<void> writeBytes(String blobKey, Uint8List bytes);
  Future<Uint8List?> readBytes(String blobKey);
  Future<void> deleteBytes(String blobKey);
}

OfflineUploadBlobStore createOfflineUploadBlobStore() =>
    createOfflineUploadBlobStoreImpl();
