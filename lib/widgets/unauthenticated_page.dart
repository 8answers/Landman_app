import 'package:flutter/material.dart';

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
