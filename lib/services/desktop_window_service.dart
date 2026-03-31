import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DesktopWindowService {
  static const MethodChannel _channel = MethodChannel('landman/window');

  static bool get _isDesktop {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  static Future<void> bringToFrontIfDesktop() async {
    if (!_isDesktop) return;
    try {
      await _channel.invokeMethod<void>('activateApp');
    } catch (_) {
      // Best-effort only.
    }
  }
}
