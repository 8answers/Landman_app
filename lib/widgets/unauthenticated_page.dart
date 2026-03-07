import 'package:flutter/material.dart';

import 'startup_website_view.dart';

class UnauthenticatedPage extends StatelessWidget {
  const UnauthenticatedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: SizedBox.expand(
        child: StartupWebsiteView(),
      ),
    );
  }
}
