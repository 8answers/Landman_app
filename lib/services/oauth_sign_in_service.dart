import 'package:supabase_flutter/supabase_flutter.dart';

import 'oauth_sign_in_service_web.dart'
    if (dart.library.io) 'oauth_sign_in_service_io.dart' as impl;

class OAuthSignInService {
  static Future<void> signInWithGoogle({
    required SupabaseClient supabase,
    required String redirectTo,
  }) {
    return impl.signInWithGoogle(
      supabase: supabase,
      redirectTo: redirectTo,
    );
  }
}
