import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class DbEncryptionService {
  DbEncryptionService._();

  static const String _cipherPrefix = 'enc1:';
  static const String _configuredKey = String.fromEnvironment(
    'DB_ENCRYPTION_KEY',
    defaultValue: '',
  );
  static const String _fallbackKey = 'landman-db-encryption-key-change-me';

  static final AesGcm _aesGcm = AesGcm.with256bits();
  static final Hmac _hmac = Hmac.sha256();
  static final Sha256 _sha256 = Sha256();

  static SecretKey? _secretKey;
  static List<int>? _keyBytesCache;

  static const Map<String, Set<String>> _encryptedColumnsByTable =
      <String, Set<String>>{
    'projects': <String>{
      'project_name',
      'area_unit',
      'project_address',
      'google_maps_link',
      'total_area',
      'selling_area',
      'estimated_development_cost',
    },
    'non_sellable_areas': <String>{
      'name',
      'area',
    },
    'amenity_areas': <String>{
      'name',
      'area',
      'all_in_cost',
      'sale_price',
      'sale_value',
      'payment_amount',
      'buyer_name',
      'payment',
      'agent_name',
      'buyer_contact_number',
      'buyer_mobile_number',
    },
    'partners': <String>{
      'name',
      'amount',
    },
    'expenses': <String>{
      'item',
      'amount',
      'doc',
      'document',
      'document_no',
      'doc_no',
      'invoice_no',
      'receipt_no',
      'doc_path',
      'expense_doc_path',
      'document_path',
      'doc_extension',
      'expense_doc_extension',
      'document_extension',
    },
    'layouts': <String>{
      'name',
    },
    'plots': <String>{
      'plot_number',
      'area',
      'all_in_cost_per_sqft',
      'total_plot_cost',
      'sale_price',
      'buyer_name',
      'agent_name',
      'payments',
      'buyer_contact_number',
      'buyer_mobile_number',
    },
    'plot_partners': <String>{
      'partner_name',
    },
    'project_managers': <String>{
      'name',
      'compensation_type',
      'earning_type',
      'percentage',
      'fixed_fee',
      'monthly_fee',
      'months',
      'fee',
    },
    'agents': <String>{
      'name',
      'compensation_type',
      'earning_type',
      'percentage',
      'fixed_fee',
      'monthly_fee',
      'months',
      'per_sqft_fee',
      'per_sqm_fee',
      'fee',
    },
  };

  static const Map<String, Set<String>> _numericColumnsByTable =
      <String, Set<String>>{
    'projects': <String>{
      'total_area',
      'selling_area',
      'estimated_development_cost',
    },
    'non_sellable_areas': <String>{
      'area',
    },
    'amenity_areas': <String>{
      'area',
      'all_in_cost',
      'sale_price',
      'sale_value',
      'payment_amount',
    },
    'partners': <String>{
      'amount',
    },
    'expenses': <String>{
      'amount',
    },
    'plots': <String>{
      'area',
      'all_in_cost_per_sqft',
      'total_plot_cost',
      'sale_price',
    },
    'project_managers': <String>{
      'percentage',
      'fixed_fee',
      'monthly_fee',
      'months',
      'fee',
    },
    'agents': <String>{
      'percentage',
      'fixed_fee',
      'monthly_fee',
      'months',
      'per_sqft_fee',
      'per_sqm_fee',
      'fee',
    },
  };

  static const Map<String, Set<String>> _integerColumnsByTable =
      <String, Set<String>>{
    'project_managers': <String>{'months'},
    'agents': <String>{'months'},
  };

  static String _normalizeTableName(String table) => table.trim().toLowerCase();

  static String _normalizeColumnName(String column) =>
      column.trim().toLowerCase();

  static bool isEncryptedColumn(String table, String column) {
    final normalizedTable = _normalizeTableName(table);
    final normalizedColumn = _normalizeColumnName(column);
    return _encryptedColumnsByTable[normalizedTable]
            ?.contains(normalizedColumn) ==
        true;
  }

  static bool _isNumericColumn(String table, String column) {
    final normalizedTable = _normalizeTableName(table);
    final normalizedColumn = _normalizeColumnName(column);
    return _numericColumnsByTable[normalizedTable]
            ?.contains(normalizedColumn) ==
        true;
  }

  static bool _isIntegerColumn(String table, String column) {
    final normalizedTable = _normalizeTableName(table);
    final normalizedColumn = _normalizeColumnName(column);
    return _integerColumnsByTable[normalizedTable]
            ?.contains(normalizedColumn) ==
        true;
  }

  static dynamic _coerceNumericValue(
      String table, String column, dynamic value) {
    if (value == null) return null;
    if (!_isNumericColumn(table, column)) return value;
    final isIntegerColumn = _isIntegerColumn(table, column);

    if (value is num) {
      return isIntegerColumn ? value.toInt() : value.toDouble();
    }

    final raw = value.toString().trim();
    if (raw.isEmpty) {
      return null;
    }

    if (isIntegerColumn) {
      final directInt = int.tryParse(raw);
      if (directInt != null) return directInt;
      final parsedNum = num.tryParse(raw);
      if (parsedNum != null) return parsedNum.toInt();
      return value;
    }

    final parsedNum = num.tryParse(raw);
    if (parsedNum != null) {
      return parsedNum.toDouble();
    }
    return value;
  }

  static bool isCiphertext(dynamic value) {
    return value is String && value.startsWith(_cipherPrefix);
  }

  static String _resolvedKeyMaterial() {
    final configured = _configuredKey.trim();
    if (configured.isNotEmpty) return configured;
    return _fallbackKey;
  }

  static Future<List<int>> _resolveKeyBytes() async {
    final cached = _keyBytesCache;
    if (cached != null) return cached;
    final keyHash = await _sha256.hash(
      utf8.encode(_resolvedKeyMaterial()),
    );
    _keyBytesCache = List<int>.from(keyHash.bytes);
    return _keyBytesCache!;
  }

  static Future<SecretKey> _resolveSecretKey() async {
    final cached = _secretKey;
    if (cached != null) return cached;
    final keyBytes = await _resolveKeyBytes();
    final generated = SecretKey(keyBytes);
    _secretKey = generated;
    return generated;
  }

  static Future<List<int>> _buildDeterministicNonce({
    required String table,
    required String column,
    required String plaintext,
  }) async {
    final keyBytes = await _resolveKeyBytes();
    final context =
        '${_normalizeTableName(table)}.${_normalizeColumnName(column)}|$plaintext';
    final mac = await _hmac.calculateMac(
      utf8.encode(context),
      secretKey: SecretKey(keyBytes),
    );
    final bytes = mac.bytes;
    return bytes.sublist(0, 12);
  }

  static Future<String> encryptStringForColumn(
    String table,
    String column,
    String plaintext,
  ) async {
    if (plaintext.isEmpty) return plaintext;
    if (isCiphertext(plaintext)) return plaintext;
    if (!isEncryptedColumn(table, column)) return plaintext;

    final context =
        '${_normalizeTableName(table)}.${_normalizeColumnName(column)}';
    final nonce = await _buildDeterministicNonce(
      table: table,
      column: column,
      plaintext: plaintext,
    );
    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: await _resolveSecretKey(),
      nonce: nonce,
      aad: utf8.encode(context),
    );

    final payload = <int>[
      ...secretBox.nonce,
      ...secretBox.mac.bytes,
      ...secretBox.cipherText,
    ];
    return '$_cipherPrefix${base64Encode(payload)}';
  }

  static Future<String> decryptStringForColumn(
    String table,
    String column,
    String ciphertext,
  ) async {
    if (!isCiphertext(ciphertext)) return ciphertext;
    if (!isEncryptedColumn(table, column)) return ciphertext;

    final encoded = ciphertext.substring(_cipherPrefix.length);
    try {
      final bytes = base64Decode(encoded);
      if (bytes.length < 12 + 16) return ciphertext;

      final nonce = bytes.sublist(0, 12);
      final macBytes = bytes.sublist(12, 28);
      final cipherBytes = bytes.sublist(28);

      final context =
          '${_normalizeTableName(table)}.${_normalizeColumnName(column)}';
      final clearBytes = await _aesGcm.decrypt(
        SecretBox(
          cipherBytes,
          nonce: nonce,
          mac: Mac(macBytes),
        ),
        secretKey: await _resolveSecretKey(),
        aad: utf8.encode(context),
      );
      return utf8.decode(clearBytes);
    } catch (_) {
      return ciphertext;
    }
  }

  static Future<dynamic> _encryptValue(
    String table,
    String column,
    dynamic value,
  ) async {
    if (value == null) return null;
    if (value is String) {
      return encryptStringForColumn(table, column, value);
    }
    if (value is num) {
      if (!_isNumericColumn(table, column)) return value;
      return encryptStringForColumn(table, column, value.toString());
    }
    if (value is List) {
      final output = <dynamic>[];
      for (final item in value) {
        output.add(await _encryptValue(table, column, item));
      }
      return output;
    }
    if (value is Map) {
      final output = <String, dynamic>{};
      for (final entry in value.entries) {
        output[entry.key.toString()] =
            await _encryptValue(table, column, entry.value);
      }
      return output;
    }
    return value;
  }

  static Future<dynamic> _decryptValue(
    String table,
    String column,
    dynamic value,
  ) async {
    if (value == null) return null;
    if (value is String) {
      final decrypted = await decryptStringForColumn(table, column, value);
      return _coerceNumericValue(table, column, decrypted);
    }
    if (value is num) {
      return _coerceNumericValue(table, column, value);
    }
    if (value is List) {
      final output = <dynamic>[];
      for (final item in value) {
        output.add(await _decryptValue(table, column, item));
      }
      return output;
    }
    if (value is Map) {
      final output = <String, dynamic>{};
      for (final entry in value.entries) {
        output[entry.key.toString()] =
            await _decryptValue(table, column, entry.value);
      }
      return output;
    }
    return value;
  }

  static Future<Map<String, dynamic>> encryptRowForWrite(
    String table,
    Map<String, dynamic> row,
  ) async {
    final normalizedTable = _normalizeTableName(table);
    final encryptedColumns = _encryptedColumnsByTable[normalizedTable];
    if (encryptedColumns == null || encryptedColumns.isEmpty) {
      return Map<String, dynamic>.from(row);
    }

    final output = Map<String, dynamic>.from(row);
    for (final key in row.keys) {
      if (!isEncryptedColumn(normalizedTable, key)) continue;
      output[key] = await _encryptValue(normalizedTable, key, row[key]);
    }
    return output;
  }

  static Future<List<Map<String, dynamic>>> encryptRowsForWrite(
    String table,
    List<Map<String, dynamic>> rows,
  ) async {
    final output = <Map<String, dynamic>>[];
    for (final row in rows) {
      output.add(await encryptRowForWrite(table, row));
    }
    return output;
  }

  static Future<Map<String, dynamic>> decryptRowFromRead(
    String table,
    Map<String, dynamic> row,
  ) async {
    final normalizedTable = _normalizeTableName(table);
    final encryptedColumns = _encryptedColumnsByTable[normalizedTable];
    if (encryptedColumns == null || encryptedColumns.isEmpty) {
      return Map<String, dynamic>.from(row);
    }

    final output = Map<String, dynamic>.from(row);
    for (final key in row.keys) {
      if (!isEncryptedColumn(normalizedTable, key)) continue;
      output[key] = await _decryptValue(normalizedTable, key, row[key]);
    }
    return output;
  }

  static Future<List<Map<String, dynamic>>> decryptRowsFromRead(
    String table,
    List<dynamic> rows,
  ) async {
    final output = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (row is! Map) continue;
      output.add(
        await decryptRowFromRead(
          table,
          Map<String, dynamic>.from(row.cast<String, dynamic>()),
        ),
      );
    }
    return output;
  }

  static Future<dynamic> encryptFilterValue(
    String table,
    String column,
    dynamic value,
  ) async {
    if (!isEncryptedColumn(table, column)) return value;
    return _encryptValue(table, column, value);
  }
}
