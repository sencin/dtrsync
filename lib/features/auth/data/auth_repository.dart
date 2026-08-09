import 'package:dio/dio.dart';
import 'package:dtrsync/core/network/api_client.dart';
import 'package:dtrsync/core/storage/token_storage.dart';

class AuthRepository {
  Future<Map<String, dynamic>> login(Map<String, dynamic> payload) async {
    try {
      final response = await ApiClient.dio.post('/auth/login', data: payload);
      final data = response.data;

      if (data['token'] != null) {
        await TokenStorage.saveToken(data['token']);
      }

      if (data['id'] != null) {
        await TokenStorage.saveUserId(data['id'].toString());
      }

      if (data['role'] != null) {
        await TokenStorage.saveUserRole(data['role']);
      }

      return data;
    } on DioException catch (e) {
      throw e.response?.data['message'] ?? 'Failed to connect to server';
    }
  }
}