import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dtrsync/core/network/api_client.dart';
import 'package:dtrsync/core/utils/image_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceEngineService {
  static const int inputSize = 112;
  static const int embeddingSize = 192;
  static const double defaultThreshold = 0.80;

  late final FaceDetector _faceDetector;
  late final Interpreter _interpreter;

  bool _initialized = false;

  bool get isInitialized => _initialized;

  Future<void> initEngine() async {
    if (_initialized) return;

    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableLandmarks: true,
        enableClassification: true,
        enableContours: true,
      ),
    );

    _interpreter = await Interpreter.fromAsset(
      'assets/models/mobile_face_net.tflite',
    );

    _initialized = true;
  }

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initEngine();
    }
  }

  Future<List<Face>> detectFaces(String imagePath) async {
    await _ensureInitialized();

    final inputImage = InputImage.fromFilePath(imagePath);

    return _faceDetector.processImage(inputImage);
  }

  Future<List<Face>> detectFacesFromInputImage(InputImage inputImage) async {
    await _ensureInitialized();
    return _faceDetector.processImage(inputImage);
  }

  bool isFaceProperlyAligned(Face face) {
    final double yaw = face.headEulerAngleY ?? 0.0;   // Turning left/right
    final double pitch = face.headEulerAngleX ?? 0.0; // Looking up/down
    final double roll = face.headEulerAngleZ ?? 0.0;  // Tilting head

    // If angles exceed 12 degrees in any direction, they are not looking straight
    return yaw.abs() < 12.0 && pitch.abs() < 12.0 && roll.abs() < 12.0;
  }

  Future<img.Image> preprocessFace(String imagePath, Face face,) async {
    final bytes = await File(imagePath).readAsBytes();

    final image = img.decodeImage(bytes);

    if (image == null) {
      throw Exception('Failed to decode image');
    }

    final box = face.boundingBox;

    final x = box.left.toInt().clamp(0, image.width - 1);
    final y = box.top.toInt().clamp(0, image.height - 1);

    final width = box.width.toInt().clamp(1, image.width - x);

    final height = box.height.toInt().clamp(1, image.height - y);

    final cropped = img.copyCrop(
      image,
      x: x,
      y: y,
      width: width,
      height: height,
    );

    return img.copyResize(
      cropped,
      width: inputSize,
      height: inputSize,
    );
  }

  Future<List<double>> extractEmbeddingFromFile(String imagePath,) async {
    await _ensureInitialized();

    final faces = await detectFaces(imagePath);

    if (faces.isEmpty) {
      throw Exception('No face detected');
    }

    final processedFace = await preprocessFace(
      imagePath,
      faces.first,
    );

    return generateEmbedding(processedFace);
  }

  List<double> generateEmbedding(img.Image processedFace) {
    return _runInference(processedFace);
  }

  // ============================================================
  // FACE MATCHING
  // ============================================================

  bool compareEmbeddings(List<double> source, List<double> target, {double threshold = defaultThreshold,}) {
    if (source.length != target.length) {
      return false;
    }

    final similarity = calculateCosineSimilarity(source, target);

    debugPrint(
      'Face Cosine Similarity: $similarity | Threshold: $threshold',
    );

    return similarity > threshold;
  }

  double calculateCosineSimilarity(List<double> source, List<double> target,) {
    if (source.length != target.length) return 0.0;

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < source.length; i++) {
      dotProduct += source[i] * target[i];
      normA += source[i] * source[i];
      normB += target[i] * target[i];
    }

    if (normA == 0.0 || normB == 0.0) return 0.0;

    return dotProduct / (math.sqrt(normA) * math.sqrt(normB));
  }

  // ============================================================
  // USER REGISTRATION
  // ============================================================

  // MODIFIED: Accept imagePath directly from the camera screen
  Future<void> registerFaceOnBackend(int userId, String imagePath) async {
    await _ensureInitialized();

    final embedding = await extractEmbeddingFromFile(imagePath);

    await _uploadEmbedding(userId, embedding, imagePath);
  }

  Future<void> _uploadEmbedding(int userId, List<double> embedding, String imagePath) async {
    File? compressedFile;

    try {
      final requestDto = jsonEncode({
        'userId': userId,
        'embedding': embedding,
      });

      final originalFile = File(imagePath);
      compressedFile = await ImageUtils.compressImage(originalFile);
      final finalFile = compressedFile ?? originalFile;

      FormData formData = FormData.fromMap({
        'request': MultipartFile.fromString(
          requestDto,
          contentType: MediaType('application', 'json'),
        ),
        'image': await MultipartFile.fromFile(
          finalFile.path,
          filename: finalFile.path.split('/').last,
        ),
      });

      await ApiClient.dio.post('/v1/users/register-face', data: formData);
    } catch (e) {
      throw Exception('Failed to upload biometric data: $e');
    } finally {
      if (compressedFile != null && compressedFile.existsSync()) {
        compressedFile.deleteSync();
      }
    }
  }

  // ============================================================
  // LIVENESS CHALLENGES
  // ============================================================

  bool verifyChallenge(Face face, String challenge,) {
    switch (challenge) {
      case "Smile":
        return (face.smilingProbability ?? 0) > 0.75;

      case "Blink":
        return (face.leftEyeOpenProbability ?? 1) < 0.3 &&
            (face.rightEyeOpenProbability ?? 1) < 0.3;

      default:
        return false;
    }
  }

  // ============================================================
  // TFLITE
  // ============================================================

  List<double> _runInference(img.Image image) {
    final input = Float32List(inputSize * inputSize * 3);
    int index = 0;

    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final pixel = image.getPixel(x, y);

        input[index++] = (pixel.r - 127.5) / 127.5;
        input[index++] = (pixel.g - 127.5) / 127.5;
        input[index++] = (pixel.b - 127.5) / 127.5;
      }
    }

    final output = List.filled(embeddingSize, 0.0).reshape([1, embeddingSize]);

    _interpreter.run(
      input.reshape([1, inputSize, inputSize, 3]),
      output,
    );

    final rawEmbedding = List<double>.from(output[0]);

    return _l2Normalize(rawEmbedding);
  }

  List<double> _l2Normalize(List<double> embedding) {
    double sumSq = 0.0;
    for (double val in embedding) {
      sumSq += val * val;
    }

    final norm = math.sqrt(sumSq);
    if (norm == 0) return embedding;

    return embedding.map((val) => val / norm).toList();
  }

  // ============================================================
  // CLEANUP
  // ============================================================

  void dispose() {
    if (!_initialized) return;

    _faceDetector.close();
    _interpreter.close();

    _initialized = false;
  }
}