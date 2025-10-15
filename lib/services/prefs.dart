import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class Prefs {
  static const _kAuth = 'auth_user_v1';

  /// Save the whole login JSON map exactly as returned by API
  static Future<void> saveAuth(Map<String, dynamic> json) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kAuth, jsonEncode(json));
  }

  /// Read the saved auth object (or null if not saved)
  static Future<Map<String, dynamic>?> getAuth() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kAuth);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Clear on sign-out
  static Future<void> clearAuth() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kAuth);
  }
}
