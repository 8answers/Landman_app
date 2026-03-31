import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

const String _googleScopes =
    'openid email profile https://www.googleapis.com/auth/gmail.send';
const Map<String, String> _googleQueryParams = <String, String>{
  'access_type': 'offline',
  'prompt': 'consent',
};

Future<void> signInWithGoogle({
  required SupabaseClient supabase,
  required String redirectTo,
}) async {
  await supabase.auth.signInWithOAuth(
    OAuthProvider.google,
    redirectTo: redirectTo,
    authScreenLaunchMode: Platform.isMacOS
        ? LaunchMode.externalApplication
        : LaunchMode.platformDefault,
    scopes: _googleScopes,
    queryParams: _googleQueryParams,
  );
}
