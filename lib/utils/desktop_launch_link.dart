import 'desktop_launch_link_stub.dart'
    if (dart.library.io) 'desktop_launch_link_io.dart';

Uri? getInitialDesktopLaunchUri() {
  return getInitialDesktopLaunchUriImpl();
}
