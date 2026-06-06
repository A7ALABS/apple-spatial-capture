/// Flutter plugin API for Apple spatial capture features.
///
/// Use [AppleSpatialCapture.platform] to check feature support, launch native
/// capture flows, reconstruct models from photos, and preview local or remote
/// 3D model files on supported Apple platforms.
library;

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

  /// Current platform implementation used by the plugin.
  static AppleSpatialCapturePlatform get platform => _platform;

  /// Allows replacing platform impl in tests.
  static void setPlatform(AppleSpatialCapturePlatform value) {
    _platform = value;
  }
}

/// Platform interface implemented by the method-channel backed plugin.
abstract class AppleSpatialCapturePlatform {
  /// Emits native photogrammetry progress events for long-running operations.
  Stream<AppleSpatialCaptureProgress> get progressStream;

  /// Returns whether Object Capture or photo photogrammetry is available.
  Future<bool> isPhotogrammetrySupported();

  /// Returns whether LiDAR mesh capture is available on this device.
  Future<bool> isLiDARSupported();

  /// Returns whether RoomPlan room capture is available on this device.
  Future<bool> isRoomPlanSupported();

  /// Returns support flags for all plugin capture features.
  Future<AppleSpatialCaptureSupport> supportStatus();

  /// Starts native guided Object Capture and returns the generated model path.
  Future<String?> startPhotogrammetryCapture();

  /// Starts photo-based photogrammetry from existing image file paths.
  Future<String?> startPhotogrammetryFromImages(
    List<String> imagePaths, {
    String? operationId,
    ApplePhotogrammetryOptions options = const ApplePhotogrammetryOptions(),
  });

  /// Starts LiDAR mesh capture and returns the generated model path.
  Future<String?> startLiDARCapture();

  /// Starts RoomPlan capture and returns the generated model path.
  Future<String?> startRoomPlanCapture();

  /// Opens a local model file in the native Apple preview UI.
  Future<void> previewCapturedModel({
    required String path,
    AppleSpatialCaptureFileType? fileType,
  });

  /// Downloads and previews a remote model file.
  Future<void> previewRemoteModel({
    required String url,
    String? fileName,
    AppleSpatialCaptureFileType? fileType,
  });
}

/// Converts platform and plugin errors to [AppleSpatialCaptureError].
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
