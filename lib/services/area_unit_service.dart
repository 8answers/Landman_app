import 'package:shared_preferences/shared_preferences.dart';
import '../utils/area_unit_utils.dart';

class AreaUnitService {
  static const String _prefix = 'project_';
  static const String _suffix = '_area_unit';
  static const String defaultUnit = AreaUnitUtils.sqmUnitLabel;

  static String _key(String? projectId) =>
      '${_prefix}${projectId ?? 'default'}$_suffix';

  static Future<String> getAreaUnit(String? projectId) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key(projectId));
    return AreaUnitUtils.canonicalizeAreaUnit(stored ?? defaultUnit);
  }

  static Future<void> setAreaUnit(String? projectId, String unit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(projectId),
      AreaUnitUtils.canonicalizeAreaUnit(unit),
    );
  }
}
