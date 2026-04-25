import 'app_update_service.dart';
import 'desktop_installer_update_service_stub.dart'
    if (dart.library.io) 'desktop_installer_update_service_io.dart';

class DesktopInstallerUpdateService {
  const DesktopInstallerUpdateService._();

  static Future<bool> tryRunInstaller(AppUpdateInfo updateInfo) {
    return tryRunInstallerImpl(updateInfo);
  }
}
