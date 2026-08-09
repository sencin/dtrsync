import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:dtrsync/core/services/face_engine_service.dart';
import 'package:dtrsync/features/employee/services/liveness_result.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceLivenessScreen extends StatefulWidget {
  const FaceLivenessScreen({super.key});

  @override
  State<FaceLivenessScreen> createState() => _FaceLivenessScreenState();
}

class _FaceLivenessScreenState extends State<FaceLivenessScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {

  // --- State Variables ---
  CameraController? _controller;
  final FaceEngineService _faceEngine = FaceEngineService();
  late AnimationController _spinController;

  bool _loading = true;
  bool _processing = false;
  bool _completed = false;
  bool _isProcessingFinal = false; // Controls the final uploading/processing UI

  String? _finalMessage;

  // Guidance state variables
  String _guidanceMessage = "Position your face in the oval frame";
  Color _statusColor = Colors.orange;

  int _currentChallenge = 0;
  final List<String> _challenges = ["Smile", "Blink"];

  // --- Getters ---
  String get currentChallenge => _currentChallenge >= _challenges.length
      ? "Completed"
      : _challenges[_currentChallenge];

  bool get isChallengeComplete => _currentChallenge >= _challenges.length;

  // --- Lifecycle ---
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Set the duration to exactly 1.5 seconds for the 0-100% fill
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _initializeScreen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed && !_isProcessingFinal) {
      _initializeScreen(); // Restart if app is resumed
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _spinController.dispose();
    _controller?.dispose();
    _faceEngine.dispose();
    super.dispose();
  }

  // =======================================================================
  // INITIALIZATION PHASE
  // =======================================================================

  Future<void> _initializeScreen() async {
    try {
      await _setupFaceDetection();
      await _setupCamera();
      _setUiReady();
    } catch (e) {
      debugPrint("Initialization Error: $e");
    }
  }

  Future<void> _setupFaceDetection() async {
    await _faceEngine.initEngine();
    _challenges.shuffle();

    debugPrint("FACE ENGINE INITIALIZED");
  }

  Future<void> _setupCamera() async {
    final frontCamera = await _getFrontCamera();
    if (frontCamera == null) throw Exception("No front camera found");

    _controller = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    await _controller!.initialize();
    await _controller!.startImageStream(_processCameraImage);
    debugPrint("CAMERA STREAM STARTED");
  }

  Future<CameraDescription?> _getFrontCamera() async {
    final cameras = await availableCameras();
    return cameras.cast<CameraDescription?>().firstWhere(
          (c) => c?.lensDirection == CameraLensDirection.front,
      orElse: () => null,
    );
  }

  void _setUiReady() {
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  // =======================================================================
  // PROCESSING PHASE
  // =======================================================================

  Future<void> _processCameraImage(CameraImage image) async {
    if (_processing || _completed || !mounted) return;
    _processing = true;

    try {
      await _detectFaceFromImage(image);
    } catch (e, stack) {
      debugPrint("MLKIT ERROR: $e\n$stack");
    } finally {
      if (mounted) _processing = false;
    }
  }

  Future<void> _detectFaceFromImage(CameraImage image) async {
    final inputImage = _convertCameraImage(image);
    if (inputImage == null) return;

    final faces = await _faceEngine.detectFacesFromInputImage(inputImage);

    if (!mounted) return;

    if (faces.isEmpty) {
      setState(() {
        _guidanceMessage = "No face detected. Align inside oval";
        _statusColor = Colors.orange;
      });
    } else if (faces.length > 1) {
      setState(() {
        _guidanceMessage = "Multiple faces detected! Only 1 person allowed";
        _statusColor = Colors.red;
      });
    } else {
      final face = faces.first;

      // Calculate logical size for centering math
      final int sensorOrientation = _controller!.description.sensorOrientation;
      double logicalWidth = image.width.toDouble();
      double logicalHeight = image.height.toDouble();
      if (sensorOrientation == 90 || sensorOrientation == 270) {
        logicalWidth = image.height.toDouble();
        logicalHeight = image.width.toDouble();
      }

      // Run strict alignment/centering check before evaluating the challenge
      final String alignmentFeedback = _checkFaceAlignment(face, Size(logicalWidth, logicalHeight));

      if (alignmentFeedback == "Aligned") {
        setState(() {
          _guidanceMessage = currentChallenge;
          _statusColor = Colors.blueAccent;
        });

        _evaluateChallenge(face);
      } else {
        setState(() {
          _guidanceMessage = alignmentFeedback;
          _statusColor = Colors.orange;
        });
      }
    }
  }

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

  void _evaluateChallenge(Face face) {
    final passed = _faceEngine.verifyChallenge(face, currentChallenge);

    if (passed) {
      HapticFeedback.lightImpact();
      debugPrint("✅ PASSED CHALLENGE: $currentChallenge");
      _advanceToNextChallenge();
    }
  }

  void _advanceToNextChallenge() {
    setState(() => _currentChallenge++);

    if (isChallengeComplete) {
      _finishLiveness();
    }
  }

  // --- TRIGGER FINAL CAPTURE & RETURN RESULT ---
  Future<void> _finishLiveness() async {
    if (_completed) return;
    _completed = true;

    try {
      if (!mounted) return;

      setState(() {
        _finalMessage = "Hold still...";
        _statusColor = Colors.green;
      });

      // 1. Start the progress animation from 0% to 100%
      await _spinController.forward(from: 0.0);

      HapticFeedback.heavyImpact();

      // 2. Take final picture SAFELY while camera is still fully active
      final XFile imageFile = await _controller!.takePicture();

      if (!mounted) return;

      // 3. Save a temporary reference to the controller
      final CameraController? controllerToDispose = _controller;

      // 4. Update state to remove CameraPreview and show Processing view
      setState(() {
        _isProcessingFinal = true;
        _controller = null; // Crucial: sets to null so UI won't try to build it
      });

      // 5. Wait a tiny moment to guarantee Flutter has completely unmounted the CameraPreview widget
      await Future.delayed(const Duration(milliseconds: 150));

      // 6. NOW safely dispose the hardware in the background
      await controllerToDispose?.dispose();

      if (!mounted) return;

      Navigator.pop(context, LivenessResult(imagePath: imageFile.path));

    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Capture failed. Restarting scan...")),
      );

      // Restart logic on failure
      setState(() {
        _completed = false;
        _currentChallenge = 0;
      });
      await _initializeScreen();
    }
  }

  // =======================================================================
  // UTILITY PHASE
  // =======================================================================

  InputImage? _convertCameraImage(CameraImage image) {
    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final sensorOrientation = _controller!.description.sensorOrientation;
      final rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ??
          InputImageRotation.rotation0deg;

      final format = Platform.isAndroid
          ? InputImageFormat.nv21
          : InputImageFormat.bgra8888;

      final metadata = InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      );

      return InputImage.fromBytes(bytes: bytes, metadata: metadata);
    } catch (e) {
      debugPrint("InputImage conversion error: $e");
      return null;
    }
  }

  // =======================================================================
  // UI PHASE
  // =======================================================================

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
        leading: _isProcessingFinal
            ? const SizedBox() // Hide back button when processing
            : IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "Liveness Verification",
          style: TextStyle(color: colorScheme.onSurface, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: _isProcessingFinal
            ? _buildProcessingView(colorScheme, theme)
            : _loading || _controller == null
            ? const Center(child: CircularProgressIndicator())
            : _buildCameraScannerView(colorScheme),
      ),
    );
  }

  Widget _buildProcessingView(ColorScheme colorScheme, ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 32),
            Text(
              "Verifying Liveness",
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              "Finalizing capture, please wait a moment...",
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
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              CameraPreview(_controller!),

              // Dynamic Overlay Painter with Progress Arc Animation
              AnimatedBuilder(
                animation: _spinController,
                builder: (context, child) {
                  return CustomPaint(
                    painter: _FaceAlignmentOverlayPainter(
                      borderColor: _statusColor,
                      spinAnimationValue: _completed ? _spinController.value : null,
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
}

// =======================================================================
// OBLONG / OVAL OVERLAY PAINTER WITH PROGRESS ANIMATION
// =======================================================================
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
        ..strokeCap = StrokeCap.round;

      // Start at top center (-90 degrees)
      const double startAngle = -math.pi / 2;
      // Sweep clockwise based on progress (0 to 360 degrees)
      final double sweepAngle = spinAnimationValue! * 2 * math.pi;

      canvas.drawArc(
        ovalRect,
        startAngle,
        sweepAngle,
        false,
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