// lib/services/auth_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  // ====== ENDPOINTS ======
  static const String _signupUrl =
      'https://access-asset-management-h9fmcwbhcwf5h5f7.westus3-01.azurewebsites.net/api/signup?code=Pe7gWTppL32N6o-730erfZ4zeIzcgKHhmRW9in61pQ-9AzFukq-nfw==';

  static const String _loginUrl =
      'https://access-asset-management-h9fmcwbhcwf5h5f7.westus3-01.azurewebsites.net/api/Login?code=eG9RoJVXy7FbSFvLZVhcbaWmfPQKdXGFMzrQx-zc7V0ZAzFuKkIggw==';

  // ====== STORAGE KEYS ======
  static const String _spKeyAuth = 'auth_user_v1'; // stores whole login JSON

  // ====== SIGN UP ======
  static Future<({bool ok, String msg})> signup({
    required String username,
    required String email,
    required String phone,
    required String password,
  }) async {
    try {
      final r = await http.post(
        Uri.parse(_signupUrl),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username.trim(),
          'email': email.trim(),
          'phonenumber': phone.trim(),
          'password': password,
        }),
      );

      if (r.statusCode == 200 || r.statusCode == 201) {
        return (ok: true, msg: 'Account created');
      }
      if (r.statusCode == 409) return (ok: false, msg: 'Username or email already exists');
      if (r.statusCode == 400) {
        return (ok: false, msg: r.body.isNotEmpty ? r.body : 'Invalid input');
      }
      return (ok: false, msg: 'Server error (${r.statusCode})');
    } catch (e) {
      return (ok: false, msg: 'Network error: $e');
    }
  }

  // ====== LOGIN + SAVE TO PREFS ======
  static Future<({bool ok, String msg})> login({
    required String email,
    required String password,
  }) async {
    try {
      final r = await http
          .post(
            Uri.parse(_loginUrl),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json, text/plain, */*',
            },
            body: jsonEncode({'email': email.trim(), 'password': password}),
          )
          .timeout(const Duration(seconds: 60));

      // Helper to pick a readable message from server
      String _msg([String fallback = '']) {
        final b = r.body.trim();
        if (b.isEmpty) return fallback.isEmpty ? 'Server responded ${r.statusCode}' : fallback;
        try {
          final v = jsonDecode(b);
          if (v is Map) {
            for (final k in ['message', 'error', 'detail', 'msg', 'reason']) {
              final val = v[k];
              if (val is String && val.trim().isNotEmpty) return val;
            }
          } else if (v is String && v.isNotEmpty) {
            return v;
          }
        } catch (_) {/* not JSON */}
        return b;
      }

      if (r.statusCode == 200) {
        // Parse and persist the entire JSON body
        final Map<String, dynamic> data = jsonDecode(r.body);
        final sp = await SharedPreferences.getInstance();
        await sp.setString(_spKeyAuth, jsonEncode(data));
        return (ok: true, msg: (data['message'] ?? 'Login success').toString());
      }

      if (r.statusCode == 401) return (ok: false, msg: _msg('Invalid credentials'));
      if (r.statusCode == 400) return (ok: false, msg: _msg('Invalid input'));
      return (ok: false, msg: _msg('Server error'));
    } catch (e) {
      return (ok: false, msg: 'Network error: $e');
    }
  }

  // ====== READ SAVED AUTH (for Profile page, etc.) ======
  static Future<Map<String, dynamic>?> getSavedAuth() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_spKeyAuth);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // Convenience getters (optional)
  static Future<String?> getAccessToken() async {
    final j = await getSavedAuth();
    return j?['accessToken']?.toString();
  }

  static Future<String?> getUsername() async {
    final j = await getSavedAuth();
    return j?['username']?.toString();
  }

  static Future<String?> getEmail() async {
    final j = await getSavedAuth();
    return j?['email']?.toString();
  }

  static Future<String?> getPhone() async {
    final j = await getSavedAuth();
    return j?['phonenumber']?.toString();
  }

  // ====== SIGN OUT (clear saved data) ======
  static Future<void> clearSavedAuth() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_spKeyAuth);
  }
}
