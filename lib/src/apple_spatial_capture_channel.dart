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
  Future<bool> isGaussianSplatCaptureSupported() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isGaussianSplatCaptureSupported',
          ) ??
          false;
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<bool> isGaussianSplatTrainingSupported() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isGaussianSplatTrainingSupported',
          ) ??
          false;
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
      isGaussianSplatCaptureSupported(),
      isGaussianSplatTrainingSupported(),
    ]);
    return AppleSpatialCaptureSupport(
      photogrammetry: values[0],
      lidar: values[1],
      roomPlan: values[2],
      gaussianSplat: values[3],
      gaussianSplatTraining: values[4],
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
  Future<AppleGaussianSplatDataset?> startGaussianSplatCapture({
    AppleGaussianSplatCaptureOptions options =
        const AppleGaussianSplatCaptureOptions(),
  }) async {
    try {
      final payload = await _channel.invokeMapMethod<Object?, Object?>(
        'startGaussianSplatCapture',
        {'options': options.toMap()},
      );
      if (payload == null) {
        return null;
      }
      return AppleGaussianSplatDataset.fromMap(payload);
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<void> previewGaussianSplat({required String datasetPath}) async {
    final normalizedPath = datasetPath.trim();
    if (normalizedPath.isEmpty) {
      throw const AppleSpatialCaptureError(
        code: 'INVALID_PATH',
        message: 'Dataset path is required.',
      );
    }
    try {
      await _channel.invokeMethod<void>('previewGaussianSplat', {
        'datasetPath': normalizedPath,
      });
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<AppleSplatViewportSession> openSplatViewport({
    required String datasetPath,
  }) async {
    final normalizedPath = datasetPath.trim();
    if (normalizedPath.isEmpty) {
      throw const AppleSpatialCaptureError(
        code: 'INVALID_PATH',
        message: 'Dataset path is required.',
      );
    }
    try {
      final payload = await _channel.invokeMapMethod<Object?, Object?>(
        'openSplatViewport',
        {'datasetPath': normalizedPath},
      );
      if (payload == null) {
        throw const AppleSpatialCaptureError(
          code: 'VIEWPORT_OPEN_FAILED',
          message: 'The viewport session could not be created.',
        );
      }
      return AppleSplatViewportSession.fromMap(payload);
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<AppleSplatViewportSession> openSplatPlyViewport({
    required String plyPath,
  }) async {
    final normalizedPath = plyPath.trim();
    if (normalizedPath.isEmpty) {
      throw const AppleSpatialCaptureError(
        code: 'INVALID_PATH',
        message: 'Splat file path is required.',
      );
    }
    try {
      final payload = await _channel.invokeMapMethod<Object?, Object?>(
        'openSplatPlyViewport',
        {'plyPath': normalizedPath},
      );
      if (payload == null) {
        throw const AppleSpatialCaptureError(
          code: 'VIEWPORT_OPEN_FAILED',
          message: 'The viewport session could not be created.',
        );
      }
      return AppleSplatViewportSession.fromMap(payload);
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<Uint8List?> renderSplatViewport({
    required int sessionId,
    double azimuth = 0,
    double elevation = 0.35,
    double distanceScale = 1,
  }) async {
    try {
      return await _channel.invokeMethod<Uint8List>('renderSplatViewport', {
        'sessionId': sessionId,
        'azimuth': azimuth,
        'elevation': elevation,
        'distanceScale': distanceScale,
      });
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<void> closeSplatViewport({required int sessionId}) async {
    try {
      await _channel.invokeMethod<void>('closeSplatViewport', {
        'sessionId': sessionId,
      });
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<int> cleanupSplatViewport({
    required int sessionId,
    double minOpacity = 0,
    double maxWorldScale = 0,
  }) async {
    try {
      return await _channel.invokeMethod<int>('cleanupSplatViewport', {
            'sessionId': sessionId,
            'minOpacity': minOpacity,
            'maxWorldScale': maxWorldScale,
          }) ??
          0;
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<int> cropSplatViewport({
    required int sessionId,
    double keepFraction = 0.85,
  }) async {
    try {
      return await _channel.invokeMethod<int>('cropSplatViewport', {
            'sessionId': sessionId,
            'keepFraction': keepFraction,
          }) ??
          0;
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<void> snapshotSplatViewport({
    required int sessionId,
    required String path,
  }) async {
    try {
      await _channel.invokeMethod<void>('snapshotSplatViewport', {
        'sessionId': sessionId,
        'path': path,
      });
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<int> restoreSplatViewport({
    required int sessionId,
    required String path,
  }) async {
    try {
      return await _channel.invokeMethod<int>('restoreSplatViewport', {
            'sessionId': sessionId,
            'path': path,
          }) ??
          0;
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<void> saveSplatViewportEdits({
    required int sessionId,
    required String datasetPath,
  }) async {
    try {
      await _channel.invokeMethod<void>('saveSplatViewportEdits', {
        'sessionId': sessionId,
        'datasetPath': datasetPath,
      });
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<List<String>> listGaussianSplatDatasets() async {
    try {
      final paths = await _channel.invokeListMethod<String>(
        'listGaussianSplatDatasets',
      );
      return paths ?? const [];
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<AppleGaussianSplatTrainingResult> trainGaussianSplat({
    required String datasetPath,
    String? operationId,
    AppleGaussianSplatTrainingOptions options =
        const AppleGaussianSplatTrainingOptions(),
  }) async {
    final normalizedPath = datasetPath.trim();
    if (normalizedPath.isEmpty) {
      throw const AppleSpatialCaptureError(
        code: 'INVALID_PATH',
        message: 'Dataset path is required.',
      );
    }
    try {
      final payload = await _channel
          .invokeMapMethod<Object?, Object?>('trainGaussianSplat', {
            'datasetPath': normalizedPath,
            if (operationId != null && operationId.trim().isNotEmpty)
              'operationId': operationId.trim(),
            'options': options.toMap(),
          });
      if (payload == null) {
        throw const AppleSpatialCaptureError(
          code: 'TRAINING_FAILED',
          message: 'Training ended without producing a result.',
        );
      }
      return AppleGaussianSplatTrainingResult.fromMap(payload);
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<bool> cancelGaussianSplatTraining() async {
    try {
      return await _channel.invokeMethod<bool>('cancelGaussianSplatTraining') ??
          false;
    } catch (error) {
      throw toAppleSpatialCaptureError(error);
    }
  }

  @override
  Future<bool> shareGaussianSplatDataset({required String datasetPath}) async {
    final normalizedPath = datasetPath.trim();
    if (normalizedPath.isEmpty) {
      throw const AppleSpatialCaptureError(
        code: 'INVALID_PATH',
        message: 'Dataset path is required.',
      );
    }
    try {
      return await _channel.invokeMethod<bool>('shareGaussianSplatDataset', {
            'path': normalizedPath,
          }) ??
          false;
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
