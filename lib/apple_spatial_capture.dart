import 'package:flutter/services.dart';

import 'src/apple_spatial_capture_channel.dart';
import 'src/apple_spatial_capture_models.dart';

export 'src/apple_spatial_capture_models.dart';

/// Flutter-facing library for Apple 3D capture and reconstruction features:
/// RoomPlan, photogrammetry (Object Capture), LiDAR mesh scanning, and macOS
/// photo-based reconstruction.
class AppleSpatialCapture {
  AppleSpatialCapture._();

  static AppleSpatialCapturePlatform _platform = AppleSpatialCaptureChannel();

  static AppleSpatialCapturePlatform get platform => _platform;

  /// Allows replacing platform impl in tests.
  static void setPlatform(AppleSpatialCapturePlatform value) {
    _platform = value;
  }
}

abstract class AppleSpatialCapturePlatform {
  Stream<AppleSpatialCaptureProgress> get progressStream;

  Future<bool> isPhotogrammetrySupported();
  Future<bool> isLiDARSupported();
  Future<bool> isRoomPlanSupported();
  Future<AppleSpatialCaptureSupport> supportStatus();

  Future<String?> startPhotogrammetryCapture();
  Future<String?> startPhotogrammetryFromImages(
    List<String> imagePaths, {
    String? operationId,
    ApplePhotogrammetryOptions options = const ApplePhotogrammetryOptions(),
  });
  Future<String?> startLiDARCapture();
  Future<String?> startRoomPlanCapture();

  Future<void> previewCapturedModel({
    required String path,
    AppleSpatialCaptureFileType? fileType,
  });

  Future<void> previewRemoteModel({
    required String url,
    String? fileName,
    AppleSpatialCaptureFileType? fileType,
  });
}

AppleSpatialCaptureError toAppleSpatialCaptureError(Object error) {
  if (error is AppleSpatialCaptureError) {
    return error;
  }
  if (error is PlatformException) {
    return AppleSpatialCaptureError(
      code: error.code,
      message: error.message ?? 'Apple spatial capture failed.',
      details: error.details,
    );
  }
  return AppleSpatialCaptureError(code: 'UNKNOWN', message: error.toString());
}
