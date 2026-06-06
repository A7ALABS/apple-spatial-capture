/// Supported 3D model file types for native preview.
enum AppleSpatialCaptureFileType {
  /// Binary glTF model.
  glb,

  /// Text glTF model.
  gltf,

  /// Universal Scene Description ZIP model.
  usdz,

  /// Wavefront OBJ model.
  obj,
}

/// RealityKit photogrammetry reconstruction detail level.
enum ApplePhotogrammetryDetail {
  /// Fastest low-detail reconstruction.
  preview,

  /// Reduced-detail reconstruction.
  reduced,

  /// Medium-detail reconstruction.
  medium,

  /// Full-detail reconstruction.
  full,

  /// Raw reconstruction detail when supported by the platform.
  raw,
}

/// Serialized values for [ApplePhotogrammetryDetail].
extension ApplePhotogrammetryDetailValue on ApplePhotogrammetryDetail {
  /// Native method-channel value for this detail level.
  String get value {
    switch (this) {
      case ApplePhotogrammetryDetail.preview:
        return 'preview';
      case ApplePhotogrammetryDetail.reduced:
        return 'reduced';
      case ApplePhotogrammetryDetail.medium:
        return 'medium';
      case ApplePhotogrammetryDetail.full:
        return 'full';
      case ApplePhotogrammetryDetail.raw:
        return 'raw';
    }
  }
}

/// Feature matching sensitivity used by RealityKit photogrammetry.
enum ApplePhotogrammetryFeatureSensitivity {
  /// Default feature sensitivity.
  normal,

  /// Higher sensitivity for low-texture or difficult subjects.
  high,
}

/// Serialized values for [ApplePhotogrammetryFeatureSensitivity].
extension ApplePhotogrammetryFeatureSensitivityValue
    on ApplePhotogrammetryFeatureSensitivity {
  /// Native method-channel value for this feature sensitivity.
  String get value {
    switch (this) {
      case ApplePhotogrammetryFeatureSensitivity.normal:
        return 'normal';
      case ApplePhotogrammetryFeatureSensitivity.high:
        return 'high';
    }
  }
}

/// Ordering hint for selected photo samples.
enum ApplePhotogrammetrySampleOrdering {
  /// Photos are ordered around the subject.
  sequential,

  /// Photos may be in arbitrary order.
  unordered,
}

/// Serialized values for [ApplePhotogrammetrySampleOrdering].
extension ApplePhotogrammetrySampleOrderingValue
    on ApplePhotogrammetrySampleOrdering {
  /// Native method-channel value for this sample ordering.
  String get value {
    switch (this) {
      case ApplePhotogrammetrySampleOrdering.sequential:
        return 'sequential';
      case ApplePhotogrammetrySampleOrdering.unordered:
        return 'unordered';
    }
  }
}

/// User-facing reconstruction quality preset.
enum ApplePhotogrammetryTextureQuality {
  /// Lower quality and faster processing.
  low,

  /// Balanced quality and processing time.
  medium,

  /// Higher quality and slower processing.
  high,
}

/// Serialized values for [ApplePhotogrammetryTextureQuality].
extension ApplePhotogrammetryTextureQualityValue
    on ApplePhotogrammetryTextureQuality {
  /// Native method-channel value for this texture quality.
  String get value {
    switch (this) {
      case ApplePhotogrammetryTextureQuality.low:
        return 'low';
      case ApplePhotogrammetryTextureQuality.medium:
        return 'medium';
      case ApplePhotogrammetryTextureQuality.high:
        return 'high';
    }
  }
}

/// Output format requested from photo photogrammetry.
enum ApplePhotogrammetryOutputFormat {
  /// Generate a USDZ file.
  usdz,

  /// Generate OBJ assets.
  obj,
}

/// Serialized values for [ApplePhotogrammetryOutputFormat].
extension ApplePhotogrammetryOutputFormatValue
    on ApplePhotogrammetryOutputFormat {
  /// Native method-channel value for this output format.
  String get value {
    switch (this) {
      case ApplePhotogrammetryOutputFormat.usdz:
        return 'usdz';
      case ApplePhotogrammetryOutputFormat.obj:
        return 'obj';
    }
  }
}

/// Options used for photo-based photogrammetry reconstruction.
class ApplePhotogrammetryOptions {
  /// Creates photogrammetry options with platform-safe defaults.
  const ApplePhotogrammetryOptions({
    this.detail = ApplePhotogrammetryDetail.reduced,
    this.featureSensitivity = ApplePhotogrammetryFeatureSensitivity.normal,
    this.sampleOrdering = ApplePhotogrammetrySampleOrdering.unordered,
    this.textureQuality = ApplePhotogrammetryTextureQuality.low,
    this.outputFormat = ApplePhotogrammetryOutputFormat.obj,
    this.useObjectMasking = false,
  });

  /// Requested RealityKit reconstruction detail.
  final ApplePhotogrammetryDetail detail;

  /// Feature matching sensitivity for the reconstruction.
  final ApplePhotogrammetryFeatureSensitivity featureSensitivity;

  /// Hint describing whether photos are ordered around the subject.
  final ApplePhotogrammetrySampleOrdering sampleOrdering;

  /// User-facing quality preset used by the example and native layer.
  final ApplePhotogrammetryTextureQuality textureQuality;

  /// Requested model output format.
  final ApplePhotogrammetryOutputFormat outputFormat;

  /// Whether object masking should be enabled when supported.
  final bool useObjectMasking;

  /// Converts this options object to a method-channel payload.
  Map<String, Object?> toMap() {
    return {
      'detail': detail.value,
      'featureSensitivity': featureSensitivity.value,
      'sampleOrdering': sampleOrdering.value,
      'textureQuality': textureQuality.value,
      'outputFormat': outputFormat.value,
      'useObjectMasking': useObjectMasking,
    };
  }
}

/// Serialized values for [AppleSpatialCaptureFileType].
extension AppleSpatialCaptureFileTypeValue on AppleSpatialCaptureFileType {
  /// File extension value used by native preview calls.
  String get value {
    switch (this) {
      case AppleSpatialCaptureFileType.glb:
        return 'glb';
      case AppleSpatialCaptureFileType.gltf:
        return 'gltf';
      case AppleSpatialCaptureFileType.usdz:
        return 'usdz';
      case AppleSpatialCaptureFileType.obj:
        return 'obj';
    }
  }
}

/// Infers a supported model file type from a path or URL extension.
AppleSpatialCaptureFileType inferAppleSpatialCaptureFileType(String path) {
  final normalized = path.trim().toLowerCase();
  if (!normalized.contains('.')) {
    return AppleSpatialCaptureFileType.usdz;
  }
  final ext = normalized.split('.').last;
  switch (ext) {
    case 'glb':
      return AppleSpatialCaptureFileType.glb;
    case 'gltf':
      return AppleSpatialCaptureFileType.gltf;
    case 'obj':
      return AppleSpatialCaptureFileType.obj;
    case 'usdz':
    default:
      return AppleSpatialCaptureFileType.usdz;
  }
}

/// Feature availability reported by the current Apple device.
class AppleSpatialCaptureSupport {
  /// Creates a support status object.
  const AppleSpatialCaptureSupport({
    required this.photogrammetry,
    required this.lidar,
    required this.roomPlan,
  });

  /// Whether photogrammetry capture or reconstruction is supported.
  final bool photogrammetry;

  /// Whether LiDAR mesh capture is supported.
  final bool lidar;

  /// Whether RoomPlan capture is supported.
  final bool roomPlan;
}

/// Progress stage emitted by native photogrammetry operations.
enum AppleSpatialCaptureProgressStage {
  /// The operation is preparing inputs.
  preparing,

  /// The operation is ingesting selected images.
  ingesting,

  /// The operation is reconstructing geometry or textures.
  processing,

  /// The operation is finalizing output files.
  finalizing,

  /// The operation completed successfully.
  completed,

  /// The operation was cancelled.
  cancelled,

  /// The operation failed.
  failed,

  /// Informational status event.
  info,
}

AppleSpatialCaptureProgressStage _progressStageFromString(String value) {
  switch (value) {
    case 'preparing':
      return AppleSpatialCaptureProgressStage.preparing;
    case 'ingesting':
      return AppleSpatialCaptureProgressStage.ingesting;
    case 'processing':
      return AppleSpatialCaptureProgressStage.processing;
    case 'finalizing':
      return AppleSpatialCaptureProgressStage.finalizing;
    case 'completed':
      return AppleSpatialCaptureProgressStage.completed;
    case 'cancelled':
      return AppleSpatialCaptureProgressStage.cancelled;
    case 'failed':
      return AppleSpatialCaptureProgressStage.failed;
    case 'info':
    default:
      return AppleSpatialCaptureProgressStage.info;
  }
}

/// Progress payload emitted by the native photogrammetry event stream.
class AppleSpatialCaptureProgress {
  /// Creates a progress event.
  const AppleSpatialCaptureProgress({
    required this.operation,
    required this.stage,
    required this.message,
    this.progress,
    this.etaSeconds,
    this.elapsedSeconds,
    this.operationId,
    this.stepIndex,
    this.stepTotal,
    this.stepLabel,
  });

  /// Native operation name.
  final String operation;

  /// Current high-level progress stage.
  final AppleSpatialCaptureProgressStage stage;

  /// Human-readable progress message.
  final String message;

  /// Fractional progress in the range `0.0` to `1.0`, when available.
  final double? progress;

  /// Estimated remaining seconds, when the native API provides it.
  final int? etaSeconds;

  /// Elapsed seconds since the operation started, when available.
  final int? elapsedSeconds;

  /// Optional caller-provided operation identifier.
  final String? operationId;

  /// Current pipeline step index, when available.
  final int? stepIndex;

  /// Total pipeline step count, when available.
  final int? stepTotal;

  /// Human-readable pipeline step label, when available.
  final String? stepLabel;

  /// Creates a progress event from a native method-channel map.
  factory AppleSpatialCaptureProgress.fromMap(Map<Object?, Object?> map) {
    final stageRaw = (map['stage'] as String? ?? 'info').trim().toLowerCase();
    final progressRaw = map['progress'];
    final progressValue = progressRaw is num ? progressRaw.toDouble() : null;
    final etaRaw = map['etaSeconds'];
    final etaValue = etaRaw is num ? etaRaw.toInt() : null;
    final elapsedRaw = map['elapsedSeconds'];
    final elapsedValue = elapsedRaw is num ? elapsedRaw.toInt() : null;
    final stepIndexRaw = map['stepIndex'];
    final stepTotalRaw = map['stepTotal'];
    final stepIndexValue = stepIndexRaw is num ? stepIndexRaw.toInt() : null;
    final stepTotalValue = stepTotalRaw is num ? stepTotalRaw.toInt() : null;

    return AppleSpatialCaptureProgress(
      operation: (map['operation'] as String? ?? 'unknown').trim(),
      stage: _progressStageFromString(stageRaw),
      message: (map['message'] as String? ?? '').trim(),
      progress: progressValue,
      etaSeconds: etaValue,
      elapsedSeconds: elapsedValue,
      operationId: (map['operationId'] as String?)?.trim(),
      stepIndex: stepIndexValue,
      stepTotal: stepTotalValue,
      stepLabel: (map['stepLabel'] as String?)?.trim(),
    );
  }
}

/// Exception thrown by the plugin for platform and validation failures.
class AppleSpatialCaptureError implements Exception {
  /// Creates a plugin error.
  const AppleSpatialCaptureError({
    required this.code,
    required this.message,
    this.details,
  });

  /// Stable error code.
  final String code;

  /// Human-readable error message.
  final String message;

  /// Optional platform-specific error details.
  final Object? details;

  @override
  String toString() => 'AppleSpatialCaptureError($code): $message';
}
