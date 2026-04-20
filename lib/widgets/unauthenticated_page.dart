import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../pages/login_page.dart';
import 'startup_website_view.dart';

class UnauthenticatedPage extends StatelessWidget {
  final bool openSignInDirectly;
  final String? initialPath;

  const UnauthenticatedPage({
    super.key,
    this.openSignInDirectly = true,
    this.initialPath,
  });

  @override
  Widget build(BuildContext context) {
    final shouldUseNativeLogin = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);

    if (shouldUseNativeLogin) {
      return const LoginPage();
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SizedBox.expand(
        child: StartupWebsiteView(
          initialPath:
              initialPath ?? (openSignInDirectly ? '/signin' : '/index.html'),
        ),
      ),
    );
  }
}
