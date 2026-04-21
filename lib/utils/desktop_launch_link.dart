import 'desktop_launch_link_stub.dart'
    if (dart.library.io) 'desktop_launch_link_io.dart' as impl;

void registerInitialDesktopLaunchArgs(List<String> args) {
  impl.registerInitialDesktopLaunchArgs(args);
}

Uri? getInitialDesktopLaunchUri() {
  return impl.getInitialDesktopLaunchUriImpl();
}
