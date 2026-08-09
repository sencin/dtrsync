import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dtrsync/core/network/api_client.dart';
import 'package:dtrsync/core/utils/image_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AttendanceService {
  final Dio _dio = ApiClient.dio;

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<Map<String, dynamic>> submitAttendance({
    required File picture,
    required double latitude,
    required double longitude,
  }) async {
    File? compressedFile = await ImageUtils.compressImage(picture);
    final finalPicture = compressedFile ?? picture;

    final formData = FormData.fromMap({
      "latitude": latitude,
      "longitude": longitude,
      "picture": await MultipartFile.fromFile(
        finalPicture.path,
        filename: finalPicture.path.split('/').last,
      ),
    });
    try {
      final response = await _dio.post("/v1/attendances", data: formData);
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (e.response?.data != null) {
        throw e.response!.data;
      }
      throw {"message": e.message ?? "Unknown error occurred"};
    } finally {
      if (compressedFile != null && compressedFile.existsSync()) {
        compressedFile.deleteSync();
      }
    }
  }

  Future<List<dynamic>> getAllAttendance() async {
    try {
      final response = await _dio.get("/attendances");
      return response.data as List<dynamic>;
    } on DioException catch (e) {
      throw Exception(
        e.response?.data["message"] ?? "Failed to fetch attendance records",
      );
    }
  }

  Future<List<dynamic>> getDailyAttendance({int? siteId}) async {
    try {
      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);
      final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59);

      final Map<String, dynamic> queryParams = {
        'startDate': startOfDay.toIso8601String(),
        'endDate': endOfDay.toIso8601String(),
        'size': 100,
        'sort': 'dateTime,desc',
      };

      if (siteId != null) {
        queryParams['siteId'] = siteId;
      }

      final response = await _dio.get(
        '/attendances/filter',
        queryParameters: queryParams,
      );

      if (response.statusCode == 200) {
        if (response.data != null && response.data['content'] != null) {
          return response.data['content'] as List<dynamic>;
        }

        if (response.data is List) {
          return response.data as List<dynamic>;
        }

        return []; // Return empty list if no data is found
      }

      throw Exception('Failed to load attendance records');
    } on DioException catch (e) {
      throw Exception(
        e.response?.data?['message'] ??
            e.message ??
            'Unable to fetch attendance records',
      );
    } catch (e) {
      throw Exception('Attendance Error: $e');
    }
  }

  Future<String> getAttendanceStatus() async {
    final response = await _dio.get("/attendances/status");

    return response.data["nextAction"];
  }

  Future<List<dynamic>> getAttendanceHistory() async {
    final userId = await _storage.read(key: "userId");

    if (userId == null) {
      throw Exception("User ID not found");
    }

    final response = await _dio.get("/attendances/user/$userId");
    return response.data;
  }

  Future<Map<String, dynamic>> getAttendanceById(String attendanceId) async {
    final userId = await _storage.read(key: "userId");

    if (userId == null) {
      throw Exception("User ID not found");
    }

    final response = await _dio.get("/attendances/user/$userId/$attendanceId");

    return response.data;
  }

  Future<List<double>> getStoredEmbedding() async {
    try {
      final response = await ApiClient.dio.get("/v1/users/stored");

      // 1. Ensure data exists and is a Map
      final data = response.data;
      if (data == null || data["embedding"] == null) {
        throw Exception("Biometric data not found in response.");
      }

      // 2. Extract and sanitize the string
      final String embeddingStr = data["embedding"].toString();

      // 3. Split, trim each value, and parse safely
      return embeddingStr
          .split(',')
          .where(
            (s) => s.trim().isNotEmpty,
      ) // Remove empty strings from trailing commas
          .map((e) => double.parse(e.trim())) // trim() is crucial here
          .toList();
    } catch (e) {
      debugPrint("Biometric fetch error: $e");

      // Check if it's a Dio error for more context
      if (e is DioException) {
        debugPrint("Dio Error Response: ${e.response?.data}");
      }

      throw Exception(
        "Failed to load registered biometric records: ${e.toString()}",
      );
    }
  }
}