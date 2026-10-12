import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppProvider extends ChangeNotifier {
  final SharedPreferences _prefs;
  ThemeMode _themeMode;
  Locale _locale = const Locale('en');

  AppProvider(this._prefs)
    : _themeMode = _readThemeMode(_prefs),
      _isDetailed = _prefs.getBool('isDetailed') ?? false;

  static ThemeMode _readThemeMode(SharedPreferences prefs) {
    final mode = prefs.getString('themeMode');
    if (mode != null) {
      return ThemeMode.values.firstWhere(
        (m) => m.name == mode,
        orElse: () => ThemeMode.system,
      );
    }
    // Migrate the old boolean setting.
    final isDark = prefs.getBool('isDark');
    if (isDark == null) return ThemeMode.system;
    return isDark ? ThemeMode.dark : ThemeMode.light;
  }

  ThemeMode get themeMode => _themeMode;
  Locale get locale => _locale;

  bool _isDetailed;
  bool get isDetailed => _isDetailed;

  void toggleTheme(bool isDark) {
    setThemeMode(isDark ? ThemeMode.dark : ThemeMode.light);
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    _prefs.setString('themeMode', mode.name);
    notifyListeners();
  }

  void setDetailedMode(bool isDetailed) {
    _isDetailed = isDetailed;
    _prefs.setBool('isDetailed', isDetailed);
    notifyListeners();
  }

  void setLocale(Locale locale) {
    _locale = locale;
    notifyListeners();
  }
}
