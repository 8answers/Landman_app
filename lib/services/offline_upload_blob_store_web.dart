import 'dart:indexed_db';
import 'dart:typed_data';
import 'dart:html' as html;

import 'offline_upload_blob_store.dart';

class _WebOfflineUploadBlobStore implements OfflineUploadBlobStore {
  static const String _dbName = 'landman_offline_upload_blobs_v1';
  static const String _storeName = 'upload_blobs';

  Future<Database> _openDb() async {
    final factory = html.window.indexedDB;
    if (factory == null) {
      throw Exception('IndexedDB is not available in this browser');
    }
    return factory.open(
      _dbName,
      version: 1,
      onUpgradeNeeded: (VersionChangeEvent event) {
        final db = (event.target as Request).result as Database;
        if (!db.objectStoreNames!.contains(_storeName)) {
          db.createObjectStore(_storeName);
        }
      },
    );
  }

  @override
  Future<void> writeBytes(String blobKey, Uint8List bytes) async {
    final db = await _openDb();
    final tx = db.transaction(_storeName, 'readwrite');
    tx.objectStore(_storeName).put(bytes, blobKey);
    await tx.completed;
    db.close();
  }

  @override
  Future<Uint8List?> readBytes(String blobKey) async {
    final db = await _openDb();
    final tx = db.transaction(_storeName, 'readonly');
    final value = await tx.objectStore(_storeName).getObject(blobKey);
    await tx.completed;
    db.close();

    if (value == null) return null;
    if (value is Uint8List) return value;
    if (value is ByteBuffer) return Uint8List.view(value);
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is List) {
      final ints = value.whereType<num>().map((e) => e.toInt()).toList();
      return Uint8List.fromList(ints);
    }
    return null;
  }

  @override
  Future<void> deleteBytes(String blobKey) async {
    final db = await _openDb();
    final tx = db.transaction(_storeName, 'readwrite');
    tx.objectStore(_storeName).delete(blobKey);
    await tx.completed;
    db.close();
  }
}

OfflineUploadBlobStore createOfflineUploadBlobStoreImpl() =>
    _WebOfflineUploadBlobStore();
