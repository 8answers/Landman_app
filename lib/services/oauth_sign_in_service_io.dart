import 'package:supabase_flutter/supabase_flutter.dart';

const String _googleScopes =
    'openid email profile https://www.googleapis.com/auth/gmail.send';

Future<void> signInWithGoogle({
  required SupabaseClient supabase,
  required String redirectTo,
}) async {
  await supabase.auth.signInWithOAuth(
    OAuthProvider.google,
    redirectTo: redirectTo,
    authScreenLaunchMode: LaunchMode.externalApplication,
    scopes: _googleScopes,
  );
}
