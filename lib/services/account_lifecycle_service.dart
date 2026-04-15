import 'package:supabase_flutter/supabase_flutter.dart';

class DeleteAccountResult {
  const DeleteAccountResult({
    required this.deleted,
  });

  final bool deleted;
}

class AccountLifecycleService {
  static Map<String, String> _buildAuthHeaders(String accessToken) {
    return <String, String>{
      'Authorization': 'Bearer $accessToken',
      'x-supabase-auth': 'Bearer $accessToken',
    };
  }

  static Future<Map<String, dynamic>> _invokeAction(String action) async {
    final supabase = Supabase.instance.client;
    var session = supabase.auth.currentSession;
    var accessToken = (session?.accessToken ?? '').trim();
    if (accessToken.isEmpty) {
      throw Exception('Your session has expired. Please sign in again.');
    }

    var response = await supabase.functions.invoke(
      'account-lifecycle',
      headers: _buildAuthHeaders(accessToken),
      body: <String, dynamic>{
        'action': action,
      },
    );
    if (response.status == 401) {
      await supabase.auth.refreshSession();
      session = supabase.auth.currentSession;
      accessToken = (session?.accessToken ?? '').trim();
      if (accessToken.isEmpty) {
        throw Exception('Your session has expired. Please sign in again.');
      }
      response = await supabase.functions.invoke(
        'account-lifecycle',
        headers: _buildAuthHeaders(accessToken),
        body: <String, dynamic>{
          'action': action,
        },
      );
    }

    final data = response.data;
    final body =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final isSuccess = response.status >= 200 &&
        response.status < 300 &&
        body['success'] == true;
    if (isSuccess) return body;

    final rawError = (body['error'] ?? '').toString().trim();
    if (rawError.isNotEmpty) {
      throw Exception(rawError);
    }
    throw Exception('Request failed with status ${response.status}.');
  }

  static Future<DeleteAccountResult> deleteCurrentAccount() async {
    final payload = await _invokeAction('delete_account');
    final deleted = payload['deleted'] == true;
    if (!deleted) {
      throw Exception('Account deletion did not complete.');
    }

    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {
      // Best effort local cleanup after server-side deletion.
    }

    return const DeleteAccountResult(
      deleted: true,
    );
  }
}
