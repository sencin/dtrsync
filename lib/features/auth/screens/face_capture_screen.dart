import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:dtrsync/core/services/face_engine_service.dart';
import 'package:dtrsync/features/employee/screens/attendance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceCaptureScreen extends StatefulWidget {
  final int userId;
  final String role;

  const FaceCaptureScreen({
    super.key,
    required this.userId,
    required this.role,
  });

  @override
  State<FaceCaptureScreen> createState() => _FaceCaptureScreenState();
}

class _FaceCaptureScreenState extends State<FaceCaptureScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {

  final FaceEngineService _faceService = FaceEngineService();

  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  CameraDescription? _frontCamera;

  late AnimationController _spinController;

  bool _isCameraInitialized = false;
  bool _isCameraActive = false;
  bool _isDetecting = false;
  bool _isProcessingAutoCapture = false;
  bool _isAligned = false;
  bool _isUploading = false;

  // --- Liveness State Variables ---
  String _guidanceMessage = "Position your face in the oval frame";
  Color _statusColor = Colors.orange;
  String? _finalMessage;

  int _currentChallenge = 0;
  final List<String> _challenges = ["Smile", "Blink"];

  String get currentChallenge => _currentChallenge >= _challenges.length
      ? "Completed"
      : _challenges[_currentChallenge];

  bool get isChallengeComplete => _currentChallenge >= _challenges.length;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _faceService.initEngine();

    // Set the duration to exactly 1.5 seconds for the 0-100% fill
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed && !_isUploading) {
      _startLiveCamera();
    }
  }

  Future<void> _startLiveCamera() async {
    _spinController.stop();
    _spinController.reset();

    setState(() {
      _isProcessingAutoCapture = false;
      _isUploading = false;
      _isAligned = false;
      _finalMessage = null;
      _currentChallenge = 0;
      _challenges.shuffle(); // Randomize Smile/Blink order
      _guidanceMessage = "Position your face in the oval frame";
      _statusColor = Colors.orange;
    });

    try {
      _cameras = await availableCameras();
      _frontCamera = _cameras.firstWhere(
            (cam) => cam.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );

      _cameraController = CameraController(
        _frontCamera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();

      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
        _isCameraActive = true;
      });

      // START LIVE FRAME STREAM FOR AUTO-DETECTION
      _cameraController!.startImageStream(_processCameraFrame);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isCameraActive = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Camera initialization failed: $e")),
      );
    }
  }

  Future<void> _processCameraFrame(CameraImage image) async {
    if (_isDetecting || _isProcessingAutoCapture || _isUploading || !mounted) return;
    _isDetecting = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      final faces = await _faceService.detectFacesFromInputImage(inputImage);

      if (!mounted) return;

      if (faces.isEmpty) {
        _resetAlignmentProgress("No face detected. Align inside oval", Colors.orange);
      } else if (faces.length > 1) {
        _resetAlignmentProgress("Multiple faces detected! Only 1 person allowed", Colors.red);
      } else {
        final face = faces.first;

        final int sensorOrientation = _frontCamera!.sensorOrientation;
        double logicalWidth = image.width.toDouble();
        double logicalHeight = image.height.toDouble();

        if (sensorOrientation == 90 || sensorOrientation == 270) {
          logicalWidth = image.height.toDouble();
          logicalHeight = image.width.toDouble();
        }

        final String alignmentFeedback = _checkFaceAlignment(face, Size(logicalWidth, logicalHeight));

        if (alignmentFeedback == "Aligned") {
          setState(() {
            _isAligned = true;
            _guidanceMessage = currentChallenge;
            _statusColor = Colors.blueAccent;
          });

          // Evaluate the liveness challenge (Smile / Blink)
          _evaluateChallenge(face);
        } else {
          // If they move out of alignment, warn them
          _resetAlignmentProgress(alignmentFeedback, Colors.orange);
        }
      }
    } catch (_) {
    } finally {
      if (mounted) _isDetecting = false;
    }
  }

  void _resetAlignmentProgress(String message, Color color) {
    setState(() {
      _isAligned = false;
      _guidanceMessage = message;
      _statusColor = color;
    });
  }

  // --- LIVENESS CHALLENGE EVALUATION ---
  void _evaluateChallenge(Face face) {
    if (isChallengeComplete) return;

    final passed = _faceService.verifyChallenge(face, currentChallenge);

    if (passed) {
      HapticFeedback.lightImpact();
      setState(() => _currentChallenge++);

      if (isChallengeComplete) {
        _triggerFinalCapture();
      }
    }
  }

  // --- STRICT CENTERING & ALIGNMENT LOGIC ---
  String _checkFaceAlignment(Face face, Size imageSize) {
    final double yaw = face.headEulerAngleY ?? 0.0;
    final double roll = face.headEulerAngleZ ?? 0.0;
    final double pitch = face.headEulerAngleX ?? 0.0;

    if (yaw.abs() > 12.0 || pitch.abs() > 12.0 || roll.abs() > 12.0) {
      return "Look straight at the camera";
    }

    final Rect bbox = face.boundingBox;
    final double faceCenterX = bbox.left + (bbox.width / 2);
    final double faceCenterY = bbox.top + (bbox.height / 2);

    final double imageCenterX = imageSize.width / 2;
    final double imageCenterY = (imageSize.height / 2) - (imageSize.height * 0.05);

    final double maxDeviationX = imageSize.width * 0.15;
    final double maxDeviationY = imageSize.height * 0.15;

    if ((faceCenterX - imageCenterX).abs() > maxDeviationX ||
        (faceCenterY - imageCenterY).abs() > maxDeviationY) {
      return "Center your face in the oval";
    }

    final double faceWidthRatio = bbox.width / imageSize.width;
    if (faceWidthRatio < 0.35) {
      return "Move closer to the camera";
    }
    if (faceWidthRatio > 0.65) {
      return "Move slightly further away";
    }

    return "Aligned";
  }

  // --- TRIGGER FINAL CAPTURE & BACKEND SAVE ---
  Future<void> _triggerFinalCapture() async {
    if (_isProcessingAutoCapture) return;
    _isProcessingAutoCapture = true;

    try {
      if (!mounted) return;
      setState(() {
        _finalMessage = "Hold still...";
        _statusColor = Colors.green;
      });

      await _spinController.forward(from: 0.0);

      HapticFeedback.heavyImpact();

      // 2. Take final picture SAFELY while camera is still fully active
      final XFile imageFile = await _cameraController!.takePicture();

      if (!mounted) return;

      // 3. Save a temporary reference to the controller
      final CameraController? controllerToDispose = _cameraController;

      // 4. Update state to remove CameraPreview and show Uploading view
      setState(() {
        _isCameraActive = false;
        _isUploading = true;
        _cameraController = null; // Crucial: sets to null so UI won't try to build it
      });

      // 5. Wait a tiny moment to guarantee Flutter has completely unmounted the CameraPreview widget
      await Future.delayed(const Duration(milliseconds: 150));

      // 6. NOW safely dispose the hardware in the background
      await controllerToDispose?.dispose();

      // 7. Register face with backend (this is the part that takes long)
      await _faceService.registerFaceOnBackend(widget.userId, imageFile.path);

      if (!mounted) return;

      const storage = FlutterSecureStorage();
      await storage.write(key: 'hasFaceRegistered', value: 'true');

      if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Biometrics setup complete!")),
        );
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AttendanceScreen()),);
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Capture failed. Restarting scan...")),
      );

      // Re-initialize the camera from scratch if it fails
      await _startLiveCamera();
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_cameraController == null || _frontCamera == null) return null;

    final sensorOrientation = _frontCamera!.sensorOrientation;
    InputImageRotation? rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    if (image.planes.isEmpty) return null;

    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _spinController.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        // Hide back button entirely if uploading, otherwise handle normal back logic
        leading: _isUploading
            ? const SizedBox() // Prevent user from cancelling while uploading
            : _isCameraActive
            ? IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _isProcessingAutoCapture
              ? null
              : () async {
            await _cameraController?.stopImageStream();
            _cameraController?.dispose();
            setState(() => _isCameraActive = false);
          },
        )
            : null,
        title: Text(
          "Biometric Setup",
          style: TextStyle(color: colorScheme.onSurface, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: _isUploading
            ? _buildUploadingView(colorScheme, theme)
            : _isCameraActive
            ? _buildCameraScannerView(colorScheme)
            : _buildInitialInstructionView(colorScheme, theme),
      ),
    );
  }

  Widget _buildUploadingView(ColorScheme colorScheme, ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 32),
            Text(
              "Processing Biometrics",
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              "Please wait a moment while we securely register your face...",
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraScannerView(ColorScheme colorScheme) {
    if (!_isCameraInitialized || _cameraController == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              CameraPreview(_cameraController!),

              // Dynamic Overlay Painter with Animation
              AnimatedBuilder(
                animation: _spinController,
                builder: (context, child) {
                  return CustomPaint(
                    painter: _FaceAlignmentOverlayPainter(
                      borderColor: _statusColor,
                      spinAnimationValue: _isProcessingAutoCapture ? _spinController.value : null,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        _buildInstructionPanel(),
      ],
    );
  }

  Widget _buildInstructionPanel() {
    final displayText = _finalMessage ?? _guidanceMessage;

    String subText;
    if (_finalMessage != null) {
      subText = "Final Photo";
    } else if (_statusColor == Colors.blueAccent) {
      subText = "Perform the action";
    } else {
      subText = "Adjust position";
    }

    return Container(
      width: double.infinity,
      height: 140, // Fixed height avoids screen wiggle
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            subText,
            style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 60, // Fixed height for dynamic text
            child: Center(
              child: Text(
                displayText,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: _statusColor,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInitialInstructionView(ColorScheme colorScheme, ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.face_retouching_natural_rounded,
                    size: 80,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                "Biometric Registration",
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "Follow the on-screen instructions to verify liveness and register your face securely.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurface.withOpacity(0.7),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.5)),
                ),
                child: Column(
                  children: [
                    _buildTipRow(context, Icons.lightbulb_outline, "Ensure good lighting"),
                    const SizedBox(height: 16),
                    _buildTipRow(context, Icons.masks_outlined, "Remove masks or dark glasses"),
                    const SizedBox(height: 16),
                    _buildTipRow(context, Icons.emoji_emotions_outlined, "Be ready to smile or blink"),
                  ],
                ),
              ),
              const SizedBox(height: 48),
              SizedBox(
                height: 56,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _startLiveCamera,
                  child: const Text(
                    "Start Auto-Scan",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTipRow(BuildContext context, IconData icon, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: colorScheme.primary),
        const SizedBox(width: 16),
        Expanded(
          child: Text(text, style: TextStyle(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
        ),
      ],
    );
  }
}

// --- STANDARD OBLONG OVERLAY PAINTER ---
class _FaceAlignmentOverlayPainter extends CustomPainter {
  final Color borderColor;
  final double? spinAnimationValue; // Triggers the animated progress fill

  _FaceAlignmentOverlayPainter({
    required this.borderColor,
    this.spinAnimationValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()
      ..color = Colors.black.withOpacity(0.65)
      ..style = PaintingStyle.fill;

    final ovalWidth = size.width * 0.72;
    final ovalHeight = size.height * 0.52;
    final ovalRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2 - 20),
      width: ovalWidth,
      height: ovalHeight,
    );

    // Draw dark background mask
    final backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect);
    backgroundPath.fillType = PathFillType.evenOdd;
    canvas.drawPath(backgroundPath, backgroundPaint);

    if (spinAnimationValue != null) {
      // 1. Draw a faint static base ring so the user sees the track
      final baseBorderPaint = Paint()
        ..color = borderColor.withOpacity(0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0;
      canvas.drawOval(ovalRect, baseBorderPaint);

      // 2. Draw the growing progress arc (0 to 100%)
      final progressPaint = Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0
        ..strokeCap = StrokeCap.round; // Gives the growing line rounded edges

      // Start at top center (-90 degrees)
      const double startAngle = -math.pi / 2;
      // Sweep clockwise based on progress (0 to 360 degrees)
      final double sweepAngle = spinAnimationValue! * 2 * math.pi;

      canvas.drawArc(
        ovalRect,
        startAngle,
        sweepAngle,
        false, // Don't connect back to center
        progressPaint,
      );
    } else {
      // Draw standard solid border when not animating
      final borderPaint = Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0;
      canvas.drawOval(ovalRect, borderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FaceAlignmentOverlayPainter oldDelegate) {
    return oldDelegate.borderColor != borderColor ||
        oldDelegate.spinAnimationValue != spinAnimationValue;
  }
}