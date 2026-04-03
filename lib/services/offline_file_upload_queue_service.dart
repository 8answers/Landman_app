import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_project_sync_service.dart';
import 'project_storage_service.dart';
import 'offline_upload_blob_store.dart';

class OfflineFileUploadQueueService {
  static const String uploadTypeExpenseDocument = 'expense_document';
  static const String uploadTypeLayoutImage = 'layout_image';
  static const String uploadTypeAmenityLayoutImage = 'amenity_layout_image';
  static const String uploadTypeGeneralDocument = 'general_document';

  static const String _queuePrefsKey = 'offline_file_upload_queue_v1';
  static const Duration _retryInterval = Duration(seconds: 8);

  static final SupabaseClient _supabase = Supabase.instance.client;
  static final OfflineUploadBlobStore _blobStore =
      createOfflineUploadBlobStore();
  static final Random _random = Random.secure();

  static final List<Map<String, dynamic>> _queue = <Map<String, dynamic>>[];
  static bool _queueLoaded = false;
  static bool _isFlushing = false;
  static Timer? _retryTimer;

  static String? _expenseDateColumnName;
  static bool _expenseDateColumnChecked = false;
  static String? _expenseDocColumnName;
  static bool _expenseDocColumnChecked = false;
  static String? _expenseDocPathColumnName;
  static bool _expenseDocPathColumnChecked = false;
  static String? _expenseDocIdColumnName;
  static bool _expenseDocIdColumnChecked = false;
  static String? _expenseDocExtensionColumnName;
  static bool _expenseDocExtensionColumnChecked = false;

  static String _hex(int length) {
    const chars = '0123456789abcdef';
    final out = StringBuffer();
    for (int i = 0; i < length; i++) {
      out.write(chars[_random.nextInt(chars.length)]);
    }
    return out.toString();
  }

  static String _generateQueueId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return 'up_${now}_${_hex(10)}';
  }

  static bool _isLikelyNetworkError(Object error) {
    final msg = error.toString().toLowerCase();
    const markers = <String>[
      'socketexception',
      'failed host lookup',
      'xmlhttprequest error',
      'networkerror',
      'network request failed',
      'failed to fetch',
      'clientexception',
      'connection closed',
      'connection refused',
      'connection reset',
      'connection aborted',
      'software caused connection abort',
      'network is unreachable',
      'network connection was lost',
      'the network connection was lost',
      'the internet connection appears to be offline',
      'not connected to the internet',
      'could not connect to the server',
      'err_internet_disconnected',
      'nsurlerrordomain',
      'code=-1009',
      'code=-1005',
      'error -1009',
      'error -1005',
      'timeout',
      'timed out',
      'status code: 0',
      'statuscode: null',
      'temporary failure in name resolution',
      'no address associated with hostname',
      'name or service not known',
    ];
    return markers.any(msg.contains);
  }

  static bool _isProjectRowMissingForSync(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('project_row_missing_for_sync') ||
        (msg.contains('foreign key constraint') &&
            (msg.contains('project_id') || msg.contains('layout_id'))) ||
        msg.contains('violates foreign key constraint');
  }

  static Future<void> _ensureQueueLoaded() async {
    if (_queueLoaded) return;
    _queueLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_queuePrefsKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _queue
        ..clear()
        ..addAll(decoded.whereType<Map>().map<Map<String, dynamic>>(
              (row) => Map<String, dynamic>.from(row.cast<String, dynamic>()),
            ));
    } catch (_) {
      _queue.clear();
    }
  }

  static Future<void> _persistQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_queue.isEmpty) {
        await prefs.remove(_queuePrefsKey);
        return;
      }
      await prefs.setString(_queuePrefsKey, jsonEncode(_queue));
    } catch (_) {
      // Best effort.
    }
  }

  static void _ensureSyncLoop() {
    _retryTimer ??= Timer.periodic(
      _retryInterval,
      (_) => unawaited(flushPendingUploads()),
    );
    unawaited(flushPendingUploads());
  }

  static Future<void> initialize({SupabaseClient? supabase}) async {
    await _ensureQueueLoaded();
    _ensureSyncLoop();
    unawaited(flushPendingUploads(supabase: supabase));
  }

  static Future<bool> hasPendingUploads({String? projectId}) async {
    await _ensureQueueLoaded();
    final normalizedProjectId = (projectId ?? '').trim();
    if (normalizedProjectId.isEmpty) return _queue.isNotEmpty;
    return _queue.any((row) =>
        (row['projectId'] ?? '').toString().trim() == normalizedProjectId);
  }

  static Future<void> _enqueueInternal({
    required String projectId,
    required String uploadType,
    required Uint8List bytes,
    required String fileName,
    required String extension,
    required String contentType,
    required String storagePath,
    required String parentFolderId,
    int fileSizeBytes = 0,
    String layoutId = '',
    String layoutName = '',
    String expenseId = '',
    String expenseItem = '',
    String expenseCategory = '',
    String expenseAmount = '',
    String expenseDate = '',
  }) async {
    await _ensureQueueLoaded();

    final queueId = _generateQueueId();
    final blobKey = 'blob_$queueId';
    await _blobStore.writeBytes(blobKey, bytes);

    _queue.add(<String, dynamic>{
      'id': queueId,
      'projectId': projectId.trim(),
      'uploadType': uploadType,
      'blobKey': blobKey,
      'fileName': fileName.trim(),
      'extension': extension.trim().toLowerCase(),
      'contentType': contentType.trim(),
      'storagePath': storagePath.trim(),
      'parentFolderId': parentFolderId.trim(),
      'fileSizeBytes': fileSizeBytes,
      'layoutId': layoutId.trim(),
      'layoutName': layoutName.trim(),
      'expenseId': expenseId.trim(),
      'expenseItem': expenseItem.trim(),
      'expenseCategory': expenseCategory.trim(),
      'expenseAmount': expenseAmount.trim(),
      'expenseDate': expenseDate.trim(),
      'queuedAtMs': DateTime.now().millisecondsSinceEpoch,
      'attempts': 0,
      'lastError': '',
    });

    await _persistQueue();
    _ensureSyncLoop();
  }

  static Future<void> enqueueExpenseDocumentUpload({
    required String projectId,
    required Uint8List bytes,
    required String fileName,
    required String extension,
    required String contentType,
    required String storagePath,
    required String parentFolderId,
    required int fileSizeBytes,
    String expenseId = '',
    String expenseItem = '',
    String expenseCategory = '',
    String expenseAmount = '',
    String expenseDate = '',
  }) async {
    await _enqueueInternal(
      projectId: projectId,
      uploadType: uploadTypeExpenseDocument,
      bytes: bytes,
      fileName: fileName,
      extension: extension,
      contentType: contentType,
      storagePath: storagePath,
      parentFolderId: parentFolderId,
      fileSizeBytes: fileSizeBytes,
      expenseId: expenseId,
      expenseItem: expenseItem,
      expenseCategory: expenseCategory,
      expenseAmount: expenseAmount,
      expenseDate: expenseDate,
    );
  }

  static Future<void> enqueueLayoutImageUpload({
    required String projectId,
    required Uint8List bytes,
    required String fileName,
    required String extension,
    required String contentType,
    required String storagePath,
    required String parentFolderId,
    required int fileSizeBytes,
    String layoutId = '',
    String layoutName = '',
  }) async {
    await _enqueueInternal(
      projectId: projectId,
      uploadType: uploadTypeLayoutImage,
      bytes: bytes,
      fileName: fileName,
      extension: extension,
      contentType: contentType,
      storagePath: storagePath,
      parentFolderId: parentFolderId,
      fileSizeBytes: fileSizeBytes,
      layoutId: layoutId,
      layoutName: layoutName,
    );
  }

  static Future<void> enqueueAmenityLayoutImageUpload({
    required String projectId,
    required Uint8List bytes,
    required String fileName,
    required String extension,
    required String contentType,
    required String storagePath,
    required String parentFolderId,
    required int fileSizeBytes,
  }) async {
    await _enqueueInternal(
      projectId: projectId,
      uploadType: uploadTypeAmenityLayoutImage,
      bytes: bytes,
      fileName: fileName,
      extension: extension,
      contentType: contentType,
      storagePath: storagePath,
      parentFolderId: parentFolderId,
      fileSizeBytes: fileSizeBytes,
    );
  }

  static Future<void> enqueueGeneralDocumentUpload({
    required String projectId,
    required Uint8List bytes,
    required String fileName,
    required String extension,
    required String contentType,
    required String storagePath,
    required String parentFolderId,
    required int fileSizeBytes,
  }) async {
    await _enqueueInternal(
      projectId: projectId,
      uploadType: uploadTypeGeneralDocument,
      bytes: bytes,
      fileName: fileName,
      extension: extension,
      contentType: contentType,
      storagePath: storagePath,
      parentFolderId: parentFolderId,
      fileSizeBytes: fileSizeBytes,
    );
  }

  static Future<Map<String, dynamic>> _uploadAndEnsureDocumentRow({
    required String projectId,
    required String fileName,
    required String extension,
    required String contentType,
    required String storagePath,
    required String parentFolderId,
    required int fileSizeBytes,
    required Uint8List bytes,
  }) async {
    await _supabase.storage.from('documents').uploadBinary(
          storagePath,
          bytes,
          fileOptions: FileOptions(
            contentType: contentType,
            cacheControl: '3600',
            upsert: true,
          ),
        );

    final existing = await _supabase
        .from('documents')
        .select('id,extension,file_url,name')
        .eq('project_id', projectId)
        .eq('type', 'file')
        .eq('file_url', storagePath)
        .maybeSingle();

    if (existing != null) {
      return <String, dynamic>{
        'id': (existing['id'] ?? '').toString().trim(),
        'name': (existing['name'] ?? fileName).toString().trim(),
        'file_url': (existing['file_url'] ?? storagePath).toString().trim(),
        'extension': (existing['extension'] ?? extension)
            .toString()
            .trim()
            .toLowerCase(),
      };
    }

    final inserted = await _supabase
        .from('documents')
        .insert({
          'project_id': projectId,
          'name': fileName,
          'type': 'file',
          'extension': extension,
          'parent_id': parentFolderId.isEmpty ? null : parentFolderId,
          'file_url': storagePath,
          'file_size': fileSizeBytes,
        })
        .select('id,extension,file_url,name')
        .maybeSingle();

    return <String, dynamic>{
      'id': (inserted?['id'] ?? '').toString().trim(),
      'name': (inserted?['name'] ?? fileName).toString().trim(),
      'file_url': (inserted?['file_url'] ?? storagePath).toString().trim(),
      'extension':
          (inserted?['extension'] ?? extension).toString().trim().toLowerCase(),
    };
  }

  static Future<String?> _resolveExistingExpenseColumn(
      List<String> candidates) async {
    for (final column in candidates) {
      try {
        await _supabase.from('expenses').select(column).limit(1);
        return column;
      } catch (_) {
        // try next
      }
    }
    return null;
  }

  static Future<String?> _resolveExpenseDateColumnName() async {
    if (_expenseDateColumnChecked) return _expenseDateColumnName;
    _expenseDateColumnName = await _resolveExistingExpenseColumn([
      'expense_date',
      'date',
    ]);
    _expenseDateColumnChecked = true;
    return _expenseDateColumnName;
  }

  static Future<String?> _resolveExpenseDocColumnName() async {
    if (_expenseDocColumnChecked) return _expenseDocColumnName;
    _expenseDocColumnName = await _resolveExistingExpenseColumn([
      'doc',
      'document',
      'document_no',
      'doc_no',
      'invoice_no',
      'receipt_no',
    ]);
    _expenseDocColumnChecked = true;
    return _expenseDocColumnName;
  }

  static Future<String?> _resolveExpenseDocPathColumnName() async {
    if (_expenseDocPathColumnChecked) return _expenseDocPathColumnName;
    _expenseDocPathColumnName = await _resolveExistingExpenseColumn([
      'doc_path',
      'expense_doc_path',
      'document_path',
    ]);
    _expenseDocPathColumnChecked = true;
    return _expenseDocPathColumnName;
  }

  static Future<String?> _resolveExpenseDocIdColumnName() async {
    if (_expenseDocIdColumnChecked) return _expenseDocIdColumnName;
    _expenseDocIdColumnName = await _resolveExistingExpenseColumn([
      'doc_id',
      'document_id',
      'expense_document_id',
    ]);
    _expenseDocIdColumnChecked = true;
    return _expenseDocIdColumnName;
  }

  static Future<String?> _resolveExpenseDocExtensionColumnName() async {
    if (_expenseDocExtensionColumnChecked) {
      return _expenseDocExtensionColumnName;
    }
    _expenseDocExtensionColumnName = await _resolveExistingExpenseColumn([
      'doc_extension',
      'expense_doc_extension',
      'document_extension',
    ]);
    _expenseDocExtensionColumnChecked = true;
    return _expenseDocExtensionColumnName;
  }

  static String _normText(dynamic value) => (value ?? '').toString().trim();

  static String _normAmount(dynamic value) {
    final cleaned = (value ?? '').toString().replaceAll(',', '').trim();
    final parsed = double.tryParse(cleaned) ?? 0.0;
    return parsed.toStringAsFixed(2);
  }

  static String _normDate(dynamic value) {
    final raw = (value ?? '').toString().trim();
    if (raw.isEmpty) return '';
    if (raw.length >= 10) return raw.substring(0, 10);
    return raw;
  }

  static bool _looksLikeUuid(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    final regex = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    );
    return regex.hasMatch(v);
  }

  static Future<String> _resolveExpenseTargetId({
    required String projectId,
    required String expenseId,
    required String item,
    required String category,
    required String amount,
    required String expenseDate,
  }) async {
    final trimmedExpenseId = expenseId.trim();
    if (trimmedExpenseId.isNotEmpty && _looksLikeUuid(trimmedExpenseId)) {
      final byId = await _supabase
          .from('expenses')
          .select('id')
          .eq('project_id', projectId)
          .eq('id', trimmedExpenseId)
          .maybeSingle();
      if (byId != null) return trimmedExpenseId;
    }

    final dateCol = await _resolveExpenseDateColumnName();
    final selectCols = <String>['id', 'item', 'amount', 'category'];
    if (dateCol != null) selectCols.add(dateCol);

    final rows = await _supabase
        .from('expenses')
        .select(selectCols.join(','))
        .eq('project_id', projectId)
        .order('created_at', ascending: false)
        .limit(300);

    final wantedItem = _normText(item);
    final wantedCategory = _normText(category);
    final wantedAmount = _normAmount(amount);
    final wantedDate = _normDate(expenseDate);

    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw as Map);
      final rowId = _normText(row['id']);
      if (rowId.isEmpty) continue;

      if (wantedItem.isNotEmpty && _normText(row['item']) != wantedItem) {
        continue;
      }
      if (wantedCategory.isNotEmpty &&
          _normText(row['category']) != wantedCategory) {
        continue;
      }
      if (wantedAmount.isNotEmpty &&
          _normAmount(row['amount']) != wantedAmount) {
        continue;
      }
      if (wantedDate.isNotEmpty && dateCol != null) {
        if (_normDate(row[dateCol]) != wantedDate) continue;
      }
      return rowId;
    }

    return '';
  }

  static Future<void> _applyExpenseUploadResult({
    required Map<String, dynamic> op,
    required Map<String, dynamic> uploadedDoc,
  }) async {
    final projectId = _normText(op['projectId']);
    if (projectId.isEmpty) return;

    final targetExpenseId = await _resolveExpenseTargetId(
      projectId: projectId,
      expenseId: _normText(op['expenseId']),
      item: _normText(op['expenseItem']),
      category: _normText(op['expenseCategory']),
      amount: _normText(op['expenseAmount']),
      expenseDate: _normText(op['expenseDate']),
    );

    if (targetExpenseId.isEmpty) {
      throw Exception('expense_row_missing_for_upload_sync');
    }

    final docCol = await _resolveExpenseDocColumnName();
    final docPathCol = await _resolveExpenseDocPathColumnName();
    final docIdCol = await _resolveExpenseDocIdColumnName();
    final docExtensionCol = await _resolveExpenseDocExtensionColumnName();

    final payload = <String, dynamic>{};
    if (docCol != null) payload[docCol] = _normText(uploadedDoc['name']);
    if (docPathCol != null) {
      payload[docPathCol] = _normText(uploadedDoc['file_url']);
    }
    if (docIdCol != null) {
      final docId = _normText(uploadedDoc['id']);
      payload[docIdCol] = _looksLikeUuid(docId) ? docId : null;
    }
    if (docExtensionCol != null) {
      payload[docExtensionCol] =
          _normText(uploadedDoc['extension']).toLowerCase();
    }
    if (payload.isEmpty) return;

    await _supabase
        .from('expenses')
        .update(payload)
        .eq('project_id', projectId)
        .eq('id', targetExpenseId);
  }

  static Future<String> _resolveLayoutId({
    required String projectId,
    required String layoutId,
    required String layoutName,
  }) async {
    final trimmedLayoutId = layoutId.trim();
    if (trimmedLayoutId.isNotEmpty && _looksLikeUuid(trimmedLayoutId)) {
      final byId = await _supabase
          .from('layouts')
          .select('id')
          .eq('project_id', projectId)
          .eq('id', trimmedLayoutId)
          .maybeSingle();
      if (byId != null) return trimmedLayoutId;
    }

    final normalizedName = layoutName.trim().toLowerCase();
    if (normalizedName.isEmpty) return '';

    final rows = await _supabase
        .from('layouts')
        .select('id,name')
        .eq('project_id', projectId)
        .order('created_at', ascending: true);

    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw as Map);
      final rowName = _normText(row['name']).toLowerCase();
      if (rowName != normalizedName) continue;
      final rowId = _normText(row['id']);
      if (rowId.isNotEmpty) return rowId;
    }

    return '';
  }

  static Future<void> _applyLayoutImageUploadResult({
    required Map<String, dynamic> op,
    required Map<String, dynamic> uploadedDoc,
  }) async {
    final projectId = _normText(op['projectId']);
    if (projectId.isEmpty) return;

    final resolvedLayoutId = await _resolveLayoutId(
      projectId: projectId,
      layoutId: _normText(op['layoutId']),
      layoutName: _normText(op['layoutName']),
    );
    if (resolvedLayoutId.isEmpty) {
      throw Exception('layout_row_missing_for_upload_sync');
    }

    await _supabase.from('layouts').update({
      'layout_image_name': _normText(uploadedDoc['name']),
      'layout_image_path': _normText(uploadedDoc['file_url']),
      'layout_image_doc_id': _normText(uploadedDoc['id']).isEmpty
          ? null
          : _normText(uploadedDoc['id']),
      'layout_image_extension':
          _normText(uploadedDoc['extension']).toLowerCase(),
    }).eq('id', resolvedLayoutId);
  }

  static Future<void> _applyAmenityLayoutImageUploadResult({
    required Map<String, dynamic> op,
    required Map<String, dynamic> uploadedDoc,
  }) async {
    final projectId = _normText(op['projectId']);
    if (projectId.isEmpty) return;

    await _supabase.from('projects').update({
      'amenity_layout_image_name': _normText(uploadedDoc['name']),
      'amenity_layout_image_path': _normText(uploadedDoc['file_url']),
      'amenity_layout_image_doc_id': _normText(uploadedDoc['id']).isEmpty
          ? null
          : _normText(uploadedDoc['id']),
      'amenity_layout_image_extension':
          _normText(uploadedDoc['extension']).toLowerCase(),
    }).eq('id', projectId);
  }

  static Future<void> _processEntry(Map<String, dynamic> op) async {
    final projectId = _normText(op['projectId']);
    final uploadType = _normText(op['uploadType']);
    final blobKey = _normText(op['blobKey']);
    if (projectId.isEmpty || uploadType.isEmpty || blobKey.isEmpty) {
      throw Exception('invalid_offline_upload_entry');
    }

    final bytes = await _blobStore.readBytes(blobKey);
    if (bytes == null || bytes.isEmpty) {
      throw Exception('offline_upload_blob_missing');
    }

    final uploadedDoc = await _uploadAndEnsureDocumentRow(
      projectId: projectId,
      fileName: _normText(op['fileName']),
      extension: _normText(op['extension']),
      contentType: _normText(op['contentType']),
      storagePath: _normText(op['storagePath']),
      parentFolderId: _normText(op['parentFolderId']),
      fileSizeBytes: (op['fileSizeBytes'] as num?)?.toInt() ?? bytes.length,
      bytes: bytes,
    );

    switch (uploadType) {
      case uploadTypeExpenseDocument:
        await _applyExpenseUploadResult(op: op, uploadedDoc: uploadedDoc);
        break;
      case uploadTypeLayoutImage:
        await _applyLayoutImageUploadResult(op: op, uploadedDoc: uploadedDoc);
        break;
      case uploadTypeAmenityLayoutImage:
        await _applyAmenityLayoutImageUploadResult(
            op: op, uploadedDoc: uploadedDoc);
        break;
      case uploadTypeGeneralDocument:
        break;
      default:
        throw Exception('unsupported_upload_type: $uploadType');
    }
  }

  static Future<void> flushPendingUploads({
    SupabaseClient? supabase,
    String? projectId,
  }) async {
    await _ensureQueueLoaded();
    if (_queue.isEmpty || _isFlushing) return;

    final client = supabase ?? _supabase;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) return;

    _isFlushing = true;
    try {
      int index = 0;
      final normalizedProjectId = (projectId ?? '').trim();
      while (index < _queue.length) {
        final entry = _queue[index];
        final entryProjectId = _normText(entry['projectId']);
        if (normalizedProjectId.isNotEmpty &&
            entryProjectId != normalizedProjectId) {
          index++;
          continue;
        }

        try {
          if (entryProjectId.isNotEmpty) {
            await OfflineProjectSyncService.flushPendingCreates(
              supabase: client,
              userId: userId,
            );
            await ProjectStorageService.flushPendingSaves(
              projectId: entryProjectId,
            );
          }
          await _processEntry(entry);

          final blobKey = _normText(entry['blobKey']);
          if (blobKey.isNotEmpty) {
            await _blobStore.deleteBytes(blobKey);
          }

          _queue.removeAt(index);
          await _persistQueue();
          continue;
        } catch (e) {
          entry['attempts'] = ((entry['attempts'] as num?)?.toInt() ?? 0) + 1;
          entry['lastError'] = e.toString();
          await _persistQueue();

          if (_isLikelyNetworkError(e)) {
            break;
          }

          if (_isProjectRowMissingForSync(e)) {
            index++;
            continue;
          }

          // Keep entry for manual retry and continue with next.
          index++;
        }
      }
    } finally {
      _isFlushing = false;
    }
  }
}
