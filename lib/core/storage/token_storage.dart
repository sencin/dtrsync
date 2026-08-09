import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStorage {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _tokenKey = "token";

  static Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }
  static Future<void> saveUserRole(String role) async {
    await _storage.write(key: "userRole", value: role);
  }

  static Future<String?> getUserRole() async {
    return await _storage.read(key: "userRole");
  }

  static Future<void> saveUserId(String id) async {
    await _storage.write(key: "userId", value: id);
  }

  static Future<String?> getToken() async {
    return await _storage.read(key: _tokenKey);
  }

  static Future<String?> getUserId() async {
    return await _storage.read(key: "userId");
  }

  static Future<void> deleteToken() async {
    await _storage.delete(key: _tokenKey);
  }


}