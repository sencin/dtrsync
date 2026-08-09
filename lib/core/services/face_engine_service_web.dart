import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';

class FaceEngineService {
  static const int inputSize = 112;
  static const int embeddingSize = 192;
  static const double defaultThreshold = 0.80;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  Future<void> initEngine() async {
    _initialized = true;
    debugPrint("FaceEngineService (Web Stub) initialized.");
  }

  // Added missing stub for live stream detection
  Future<List<dynamic>> detectFacesFromInputImage(dynamic inputImage) async {
    throw UnsupportedError("Face detection is not supported on Flutter Web.");
  }

  bool isFaceProperlyAligned(dynamic face) {
    return false;
  }

  Future<List<dynamic>> detectFaces(String imagePath) async {
    throw UnsupportedError("Face detection is not supported on Flutter Web.");
  }

  Future<dynamic> preprocessFace(String imagePath, dynamic face) async {
    throw UnsupportedError("Face preprocessing is not supported on Flutter Web.");
  }

  Future<List<double>> extractEmbeddingFromFile(String imagePath) async {
    throw UnsupportedError("Biometric extraction is not supported on Flutter Web.");
  }

  List<double> generateEmbedding(dynamic processedFace) {
    throw UnsupportedError("Generating embeddings is not supported on Flutter Web.");
  }

  bool compareEmbeddings(
      List<double> source,
      List<double> target, {
        double threshold = defaultThreshold,
      }) {
    if (source.length != target.length) return false;
    final similarity = calculateCosineSimilarity(source, target);
    return similarity > threshold;
  }

  double calculateCosineSimilarity(List<double> source, List<double> target) {
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

  // FIXED: Added the missing 'String imagePath' argument!
  Future<void> registerFaceOnBackend(int userId, String imagePath) async {
    throw UnsupportedError("Face registration is not supported on Flutter Web.");
  }

  bool verifyChallenge(dynamic face, String challenge) {
    return false;
  }

  void dispose() {
    _initialized = false;
  }
}