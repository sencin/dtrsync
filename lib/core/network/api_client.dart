import 'package:dio/dio.dart';
import 'package:dtrsync/core/storage/token_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiClient {
 // static const String baseUrl ='https://dtrsync.onrender.com/api';
  static const String baseUrl ='http://192.168.245.245:8082/api';
  static final Dio dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(minutes: 1),
      receiveTimeout: const Duration(minutes: 1),
    ),
  )..interceptors.add( InterceptorsWrapper(
    onRequest: (options, handler) async {
      final token = await TokenStorage.getToken();

      if (token != null) {
        options.headers["Authorization"] = "Bearer $token";
      }

      handler.next(options);
    },
  ),
  );
}