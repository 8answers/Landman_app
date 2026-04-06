import 'package:flutter/material.dart';

import 'startup_website_view.dart';

class UnauthenticatedPage extends StatelessWidget {
  final bool openSignInDirectly;

  const UnauthenticatedPage({
    super.key,
    this.openSignInDirectly = true,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SizedBox.expand(
        child: StartupWebsiteView(
          initialPath: openSignInDirectly ? '/signin' : '/index.html',
        ),
      ),
    );
  }
}
