import 'dart:async';
import 'dart:io';

import 'package:dtrsync/features/auth/screens/auth_screen.dart';
import 'package:dtrsync/features/employee/screens/attendance_history_widget.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dtrsync/core/network/api_client.dart';
import 'package:dtrsync/core/storage/token_storage.dart';
import 'package:dtrsync/core/services/face_engine_service.dart';
import 'package:dtrsync/features/employee/services/attendance_service.dart';
import 'package:dtrsync/features/employee/services/liveness_result.dart';
import 'package:dtrsync/features/employee/screens/face_liveness_screen.dart';

/// Helper for retrieving high-accuracy location
class LocationHelper {
  static Future<Position> getHyperAccuratePosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permissions are denied.');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permissions are permanently denied.');
    }

    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.bestForNavigation,
    );
  }
}

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({Key? key}) : super(key: key);

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  // === Services ===
  final AttendanceService attendanceService = AttendanceService();
  final FaceEngineService faceEngineService = FaceEngineService();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final GlobalKey<AttendanceHistoryWidgetState> _historyKey = GlobalKey<AttendanceHistoryWidgetState>();

  // === User Data State ===
  String _userName = "Loading...";
  String? _profilePictureUrl;
  bool _isUserLoading = true;

  // === Attendance Status State ===
  String _punchType = "Time in"; // Stores response from /punch-type ("Time IN" or "Time OUT")
  bool _isStatusLoading = true;
  bool _isLoading = false;

  bool get _isClockInMode => _punchType.toUpperCase().contains("IN");

  File? _selectedImage;
  List<dynamic> _history = [];

  // === Time & Date State ===
  DateTime _currentDateTime = DateTime.now();
  Timer? _clockTimer;

  // === Map & Location State ===
  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  double? _currentLatitude;
  double? _currentLongitude;
  bool _isMapLoading = true;
  StreamSubscription<Position>? _positionStream;

  @override
  void initState() {
    super.initState();

    // 1. Initialize Face Engine
    faceEngineService.initEngine();

    // 2. Fetch Initial Data concurrently
    _fetchInitialData();

    // 3. Start Location Tracking & Initial Map Position
    _startLiveLocationTracking();

    // 4. Start Live Digital Clock Ticker
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _currentDateTime = DateTime.now();
        });
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _positionStream?.cancel();
    faceEngineService.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // ===========================================================================
  // INITIAL DATA & STATUS LOGIC
  // ===========================================================================

  Future<void> _fetchInitialData() async {
    await Future.wait([
      _loadEmployeeData(),
      loadStatus(),
      loadHistory(),
    ]);
  }

  Future<void> _loadEmployeeData() async {
    try {
      final String? userId = await TokenStorage.getUserId();

      if (userId == null || userId.isEmpty) {
        await _loadEmployeeNameFromStorage();
        return;
      }

      final response = await ApiClient.dio.get('/v1/users/$userId');

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        final String firstName = data['firstName'] ?? '';
        final String lastName = data['lastName'] ?? '';
        final String fullName = '$firstName $lastName'.trim();

        if (mounted) {
          setState(() {
            _userName = fullName.isNotEmpty ? fullName : "Employee";
            _profilePictureUrl = data['profilePictureUrl'];
            _isUserLoading = false;
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching profile via API: $e");
      await _loadEmployeeNameFromStorage();
    }
  }

  Future<void> _loadEmployeeNameFromStorage() async {
    try {
      final firstName = await _storage.read(key: 'firstName');
      final lastName = await _storage.read(key: 'lastName');
      if (mounted) {
        setState(() {
          if ((firstName != null && firstName.isNotEmpty) ||
              (lastName != null && lastName.isNotEmpty)) {
            _userName = "${firstName ?? ''} ${lastName ?? ''}".trim();
          } else {
            _userName = "Employee";
          }
          _isUserLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Error reading secure storage: $e");
      if (mounted) {
        setState(() {
          _userName = "Employee";
          _isUserLoading = false;
        });
      }
    }
  }

  Future<void> loadStatus() async {
    try {
      final response = await ApiClient.dio.get('/v1/attendances/punch-type');

      if (response.statusCode == 200 && response.data != null) {
        if (!mounted) return;
        setState(() {
          // Extract punchType ("Time IN" or "Time OUT")
          _punchType = response.data['punchType'] ?? "Time IN";
          _isStatusLoading = false;
        });
      }
    } on DioException catch (e) {
      debugPrint("Dio error fetching punch type: ${e.message}");
      if (mounted) setState(() => _isStatusLoading = false);
    } catch (e) {
      debugPrint("Error fetching punch type: $e");
      if (mounted) setState(() => _isStatusLoading = false);
    }
  }

  Future<void> loadHistory() async {
    try {
      final data = await attendanceService.getAttendanceHistory();
      if (!mounted) return;
      setState(() {
        _history = data;
      });
    } catch (e) {
      debugPrint("Error fetching attendance history: $e");
    }
  }

  // ===========================================================================
  // LOCATION & MAP LOGIC
  // ===========================================================================

  void _startLiveLocationTracking() async {
    try {
      // Get initial position first to avoid map delay
      final Position initialPosition = await LocationHelper
          .getHyperAccuratePosition();
      _updateLocationState(initialPosition);

      const locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      );

      _positionStream =
          Geolocator.getPositionStream(locationSettings: locationSettings)
              .listen((Position position) {
            _updateLocationState(position);
          });
    } catch (e) {
      debugPrint("Error initializing live location: $e");
      if (mounted) {
        setState(() {
          _isMapLoading = false;
        });
      }
    }
  }

  void _updateLocationState(Position position) {
    if (!mounted) return;
    final latLng = LatLng(position.latitude, position.longitude);

    setState(() {
      _currentLatitude = position.latitude;
      _currentLongitude = position.longitude;
      _currentPosition = latLng;
      _isMapLoading = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentPosition != null) {
        _mapController.move(_currentPosition!, 16.0);
      }
    });
  }

  Future<void> attendanceAction() async {
    try {
      setState(() {
        _isLoading = true;
      });

      final String actionDone = _isClockInMode ? "Time In" : "Time Out";

      // 1. Get high-accuracy position
      final Position position = await LocationHelper.getHyperAccuratePosition();

      // 2. Fetch stored embedding from backend
      final List<double> storedEmbedding = await attendanceService
          .getStoredEmbedding();

      // 3. Perform Liveness Screen Face Capture
      final LivenessResult? result = await Navigator.push<LivenessResult>(
        context,
        MaterialPageRoute(builder: (_) => const FaceLivenessScreen()),
      );

      if (result == null) return; // User cancelled liveness check

      final File imageFile = File(result.imagePath);
      if (mounted) {
        setState(() {
          _selectedImage = imageFile;
        });
      }

      // 4. Extract live embedding & compare
      final List<double> liveEmbedding =
      await faceEngineService.extractEmbeddingFromFile(result.imagePath);

      final bool isFaceMatch = faceEngineService.compareEmbeddings(
        storedEmbedding,
        liveEmbedding,
        threshold: 0.65,
      );

      if (!isFaceMatch) {
        throw Exception(
            "Biometric verification failed. Face does not match the registered account.");
      }

      // 5. Submit attendance (Multipart Form: latitude, longitude, picture)
      await attendanceService.submitAttendance(
        picture: imageFile,
        latitude: position.latitude,
        longitude: position.longitude,
      );

      // 6. Update local map coordinates
      if (mounted) {
        setState(() {
          _currentLatitude = position.latitude;
          _currentLongitude = position.longitude;
          _currentPosition = LatLng(position.latitude, position.longitude);
        });
        _mapController.move(_currentPosition!, 16.0);
      }

      // 7. Refresh status and history list
      await loadStatus();
      await loadHistory();
      _historyKey.currentState?.loadRecentHistory();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("$actionDone recorded successfully!")),
      );
    } catch (e) {
      if (!mounted) return;

      String errorMessage = "An unexpected error occurred.";
      if (e is DioException) {
        errorMessage = e.response?.data?['message'] ?? e.message ??
            "Server error occurred.";
      } else if (e is Map) {
        errorMessage = e['message'] ?? e.toString();
      } else {
        errorMessage = e.toString().replaceAll("Exception: ", "");
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Theme
              .of(context)
              .colorScheme
              .error,
          content: Text(errorMessage),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _selectedImage = null;
        });
      }
    }
  }

  // ===========================================================================
  // UI HELPERS & DIALOGS
  // ===========================================================================

  bool get _isMorning =>
      _currentDateTime.hour >= 5 && _currentDateTime.hour < 12;

  bool get _isAfternoon =>
      _currentDateTime.hour >= 12 && _currentDateTime.hour < 18;

  String _getSessionBackground() {
    if (_isMorning) {
      return 'https://images.unsplash.com/photo-1470252649378-9c29740c9fa8?q=80&w=1000';
    }
    if (_isAfternoon) {
      return 'https://images.unsplash.com/photo-1507525428034-b723cf961d3e?q=80&w=1000';
    }
    return 'https://images.unsplash.com/photo-1506703719100-a0f3a48c0f86?q=80&w=1000';
  }

  Color _getSessionTextColor() {
    return _isMorning ? const Color(0xFF2D3142) : Colors.white;
  }

  Color _getSessionButtonColor(ThemeData theme) {
    if (_isMorning) return const Color(0xFFE89A5E);
    if (_isAfternoon) return const Color(0xFFDCA73E);
    return const Color(0xFF1E2230);
  }

  void _showLogoutDialog() async {
    final colorScheme = Theme
        .of(context)
        .colorScheme;
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) =>
          AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            title: const Text("Logout"),
            content: const Text("Are you sure you want to log out?"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text("Cancel",
                    style: TextStyle(color: colorScheme.onSurfaceVariant)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.error,
                  foregroundColor: colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text("Logout"),
              ),
            ],
          ),
    );

    if (confirm == true) {
      await TokenStorage.deleteToken();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const AuthScreen()),
            (route) => false,
      );
    }
  }

  // ===========================================================================
  // BUILD METHOD & UI SECTIONS
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(theme, colorScheme, isDark),
              const SizedBox(height: 24),
              _buildHeroTimeCard(theme),
              const SizedBox(height: 24),
              _buildActionButton(theme),
              const SizedBox(height: 24),
              _buildMapSection(theme, colorScheme, isDark),
              const SizedBox(height: 24),
              AttendanceHistoryWidget(key: _historyKey),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme colorScheme, bool isDark) {
    return Row(
      children: [
        GestureDetector(
          onTap: () {},
          child: CircleAvatar(
            radius: 28,
            backgroundColor: isDark
                ? colorScheme.surfaceContainerHighest
                : colorScheme.surfaceVariant,
            backgroundImage: _profilePictureUrl != null ? NetworkImage(
                _profilePictureUrl!) : null,
            child: _profilePictureUrl == null
                ? Icon(Icons.person_rounded, color: colorScheme.primary)
                : null,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Good ${_isMorning ? 'Morning' : _isAfternoon
                    ? 'Afternoon'
                    : 'Evening'},",
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant.withOpacity(0.8),
                ),
              ),
              _isUserLoading
                  ? Container(
                height: 20,
                width: 120,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              )
                  : Text(
                _userName,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: Icon(Icons.logout_rounded, color: colorScheme.onSurface),
          onPressed: _showLogoutDialog,
        ),
      ],
    );
  }

  Widget _buildHeroTimeCard(ThemeData theme) {
    final timeString = DateFormat('hh:mm').format(_currentDateTime);
    final amPmString = DateFormat('a').format(_currentDateTime);
    final dateString = DateFormat('EEEE, MMM dd, yyyy').format(
        _currentDateTime);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: theme.colorScheme.primaryContainer,
        image: DecorationImage(
          image: NetworkImage(_getSessionBackground()),
          fit: BoxFit.cover,
          colorFilter: ColorFilter.mode(
            Colors.black.withOpacity(0.2),
            BlendMode.darken,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    _isClockInMode ? Icons.timer_outlined : Icons.work_outline,
                    color: _getSessionTextColor(),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isStatusLoading
                        ? "Loading status..."
                        : (_isClockInMode ? "Ready to Start" : "Shift Active"),
                    style: TextStyle(
                      color: _getSessionTextColor(),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              if (!_isClockInMode && !_isStatusLoading)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _getSessionTextColor().withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: _getSessionTextColor().withOpacity(0.2)),
                  ),
                  child: Text(
                    "Live",
                    style: TextStyle(
                      color: _getSessionTextColor(),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            dateString,
            style: TextStyle(
              color: _getSessionTextColor().withOpacity(0.8),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                timeString,
                style: TextStyle(
                  color: _getSessionTextColor(),
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -1.5,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                amPmString,
                style: TextStyle(
                  color: _getSessionTextColor().withOpacity(0.8),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(ThemeData theme) {
    return Container(
      height: 54,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(
                theme.brightness == Brightness.dark ? 0.3 : 0.12),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: _isClockInMode
              ? _getSessionButtonColor(theme)
              : theme.colorScheme.secondary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
        onPressed: (_isLoading || _isStatusLoading) ? null : attendanceAction,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: (_isLoading || _isStatusLoading)
              ? const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
                color: Colors.white, strokeWidth: 2.5),
          )
              : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                "$_punchType Now", // Displays "Time IN Now" or "Time OUT Now"
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapSection(ThemeData theme, ColorScheme colorScheme,
      bool isDark) {
    return Column(
      children: [
        Container(
          height: 140,
          width: double.infinity,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: _isMapLoading || _currentPosition == null
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    "Locating...",
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
                : FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentPosition!,
                initialZoom: 16.0,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.none,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.yourcompany.app',
                  tileBuilder: isDark
                      ? (context, tileWidget, tile) =>
                      ColorFiltered(
                        colorFilter: const ColorFilter.matrix([
                          -1, 0, 0, 0, 255,
                          0, -1, 0, 0, 255,
                          0, 0, -1, 0, 255,
                          0, 0, 0, 1, 0,
                        ]),
                        child: tileWidget,
                      )
                      : null,
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentPosition!,
                      width: 45,
                      height: 45,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colorScheme.primary.withOpacity(0.3),
                            ),
                          ),
                          Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(
                                  color: colorScheme.primary, width: 3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          "Current Location",
          style: theme.textTheme.bodySmall?.copyWith(
            color: isDark ? Colors.white : Colors.black,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}