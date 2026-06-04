import 'package:flutter/services.dart';

import '../apple_spatial_capture.dart';

class AppleSpatialCaptureChannel implements AppleSpatialCapturePlatform {
  static const MethodChannel _channel = MethodChannel('apple_spatial_capture');
  static const EventChannel _progressChannel = EventChannel(
    'apple_spatial_capture/progress',
  );

  @override
  Stream<AppleSpatialCaptureProgress> get progressStream {
    return _progressChannel.receiveBroadcastStream().map((raw) {
      if (raw is Map) {
        final mapped = raw.map(
          (key, value) => MapEntry(key as Object?, value as Object?),
        );
        return AppleSpatialCaptureProgress.fromMap(mapped);
      }
      throw const AppleSpatialCaptureError(
        code: 'INVALID_PROGRESS_EVENT',
        message: 'Received invalid progress event payload.',
      );
    });
  }

  @override
  Future<bool> isPhotogrammetrySupported() async {
    try {
      return await _channel.invokeMethod<bool>('isObjectCaptureSupported') ??
          false;
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<bool> isLiDARSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isLiDARSupported') ?? false;
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<bool> isRoomPlanSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isRoomPlanSupported') ?? false;
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<AppleSpatialCaptureSupport> supportStatus() async {
    final values = await Future.wait<bool>([
      isPhotogrammetrySupported(),
      isLiDARSupported(),
      isRoomPlanSupported(),
    ]);
    return AppleSpatialCaptureSupport(
      photogrammetry: values[0],
      lidar: values[1],
      roomPlan: values[2],
    );
  }

  @override
  Future<String?> startPhotogrammetryCapture() async {
    try {
      return await _channel.invokeMethod<String>('startObjectCapture');
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<String?> startPhotogrammetryFromImages(
    List<String> imagePaths, {
    String? operationId,
    ApplePhotogrammetryOptions options = const ApplePhotogrammetryOptions(),
  }) async {
    final normalizedPaths = imagePaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList();
    if (normalizedPaths.length < 3) {
      throw const AppleSpatialCaptureError(
        code: 'INSUFFICIENT_IMAGES',
        message: 'Select at least 3 photos to generate a model.',
      );
    }

    try {
      return await _channel
          .invokeMethod<String>('startPhotogrammetryFromImages', {
            'imagePaths': normalizedPaths,
            if (operationId != null && operationId.trim().isNotEmpty)
              'operationId': operationId.trim(),
            'options': options.toMap(),
          });
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<String?> startLiDARCapture() async {
    try {
      return await _channel.invokeMethod<String>('startLiDARCapture');
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<String?> startRoomPlanCapture() async {
    try {
      return await _channel.invokeMethod<String>('startRoomPlanCapture');
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<void> previewCapturedModel({
    required String path,
    AppleSpatialCaptureFileType? fileType,
  }) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) {
      throw const AppleSpatialCaptureError(
        code: 'INVALID_PATH',
        message: 'Model path is required.',
      );
    }
    try {
      await _channel.invokeMethod<void>('previewCapturedModel', {
        'path': normalizedPath,
        'fileType':
            fileType?.value ??
            inferAppleSpatialCaptureFileType(normalizedPath).value,
      });
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<void> previewRemoteModel({
    required String url,
    String? fileName,
    AppleSpatialCaptureFileType? fileType,
  }) async {
    final normalizedUrl = url.trim();
    if (normalizedUrl.isEmpty) {
      throw const AppleSpatialCaptureError(
        code: 'INVALID_URL',
        message: 'Model URL is required.',
      );
    }

    final resolvedType =
        fileType ?? inferAppleSpatialCaptureFileType(fileName ?? normalizedUrl);
    final resolvedFileName = (fileName == null || fileName.trim().isEmpty)
        ? 'model.${resolvedType.value}'
        : fileName.trim();

    try {
      await _channel.invokeMethod<void>('previewRemoteModel', {
        'url': normalizedUrl,
        'fileName': resolvedFileName,
        'fileType': resolvedType.value,
      });
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }
}
