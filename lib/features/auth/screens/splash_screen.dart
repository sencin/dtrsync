import 'package:dtrsync/core/network/api_client.dart';
import 'package:dtrsync/core/storage/token_storage.dart';
import 'package:dtrsync/features/admin/screens/admin_dashboard_screen.dart';
import 'package:dtrsync/features/auth/screens/auth_screen.dart';
import 'package:dtrsync/features/auth/screens/face_capture_screen.dart';
import 'package:dtrsync/features/employee/screens/attendance_screen.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkLoginAndRoute();
  }

  // ADD THESE IMPORTS AT THE TOP OF YOUR FILE
// import 'package:dtrsync/features/admin/screens/admin_dashboard_screen.dart';
// import 'package:dtrsync/features/employee/screens/attendance_screen.dart';

  Future<void> _checkLoginAndRoute() async {
    try {
      final String? token = await TokenStorage.getToken();
      final String? userIdStr = await TokenStorage.getUserId();

      if (token == null || userIdStr == null || userIdStr.isEmpty) {
        _navigateToLogin();
        return;
      }

      final int? userId = int.tryParse(userIdStr);
      if (userId == null) {
        _navigateToLogin();
        return;
      }

      final userResponse = await ApiClient.dio.get('/v1/users/$userIdStr');

      if (userResponse.statusCode != 200 || userResponse.data == null) {
        _navigateToLogin();
        return;
      }

      final userData = userResponse.data;
      final String role = (userData['role'] ?? 'EMPLOYEE').toString().toUpperCase();
      final bool isAdmin = role == "ADMIN";

      // 3. Check Face Registration Status
      bool hasFaceRegistered = false;
      try {
        final faceResponse = await ApiClient.dio.get('/v1/users/stored');
        if (faceResponse.statusCode == 200) {
          hasFaceRegistered = true;
        }
      } on DioException catch (e) {
        // 404 indicates no face biometric data registered
        if (e.response?.statusCode == 404) {
          hasFaceRegistered = false;
        }
      }

      if (!mounted) return;

      if (!isAdmin && !hasFaceRegistered) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => FaceCaptureScreen(userId: userId, role: role),
          ),
        );
        return;
      }

      // CONDITION 2: User is an Admin
      if (isAdmin) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => const AdminDashboardScreen(),
          ),
        );
        return;
      }

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const AttendanceScreen(),
        ),
      );

    } on DioException catch (e) {
      debugPrint("Dio error on splash check: ${e.message}");
      if (!mounted) return;

      if (e.response?.statusCode == 401) {
        await TokenStorage.deleteToken();
      }

      _navigateToLogin();
    } catch (e) {
      debugPrint("General error on splash check: $e");
      if (!mounted) return;
      _navigateToLogin();
    }
  }

  void _navigateToLogin() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.badge_rounded,
              size: 80,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 24),
            CircularProgressIndicator(
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}