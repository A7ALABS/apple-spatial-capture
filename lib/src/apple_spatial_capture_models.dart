enum AppleSpatialCaptureFileType { glb, gltf, usdz, obj }

enum ApplePhotogrammetryDetail { preview, reduced, medium, full, raw }

extension ApplePhotogrammetryDetailValue on ApplePhotogrammetryDetail {
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

enum ApplePhotogrammetryFeatureSensitivity { normal, high }

extension ApplePhotogrammetryFeatureSensitivityValue
    on ApplePhotogrammetryFeatureSensitivity {
  String get value {
    switch (this) {
      case ApplePhotogrammetryFeatureSensitivity.normal:
        return 'normal';
      case ApplePhotogrammetryFeatureSensitivity.high:
        return 'high';
    }
  }
}

enum ApplePhotogrammetrySampleOrdering { sequential, unordered }

extension ApplePhotogrammetrySampleOrderingValue
    on ApplePhotogrammetrySampleOrdering {
  String get value {
    switch (this) {
      case ApplePhotogrammetrySampleOrdering.sequential:
        return 'sequential';
      case ApplePhotogrammetrySampleOrdering.unordered:
        return 'unordered';
    }
  }
}

enum ApplePhotogrammetryTextureQuality { low, medium, high }

extension ApplePhotogrammetryTextureQualityValue
    on ApplePhotogrammetryTextureQuality {
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

enum ApplePhotogrammetryOutputFormat { usdz, obj }

extension ApplePhotogrammetryOutputFormatValue
    on ApplePhotogrammetryOutputFormat {
  String get value {
    switch (this) {
      case ApplePhotogrammetryOutputFormat.usdz:
        return 'usdz';
      case ApplePhotogrammetryOutputFormat.obj:
        return 'obj';
    }
  }
}

class ApplePhotogrammetryOptions {
  const ApplePhotogrammetryOptions({
    this.detail = ApplePhotogrammetryDetail.reduced,
    this.featureSensitivity = ApplePhotogrammetryFeatureSensitivity.normal,
    this.sampleOrdering = ApplePhotogrammetrySampleOrdering.unordered,
    this.textureQuality = ApplePhotogrammetryTextureQuality.low,
    this.outputFormat = ApplePhotogrammetryOutputFormat.obj,
    this.useObjectMasking = false,
  });

  final ApplePhotogrammetryDetail detail;
  final ApplePhotogrammetryFeatureSensitivity featureSensitivity;
  final ApplePhotogrammetrySampleOrdering sampleOrdering;
  final ApplePhotogrammetryTextureQuality textureQuality;
  final ApplePhotogrammetryOutputFormat outputFormat;
  final bool useObjectMasking;

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

extension AppleSpatialCaptureFileTypeValue on AppleSpatialCaptureFileType {
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

class AppleSpatialCaptureSupport {
  const AppleSpatialCaptureSupport({
    required this.photogrammetry,
    required this.lidar,
    required this.roomPlan,
  });

  final bool photogrammetry;
  final bool lidar;
  final bool roomPlan;
}

enum AppleSpatialCaptureProgressStage {
  preparing,
  ingesting,
  processing,
  finalizing,
  completed,
  cancelled,
  failed,
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

class AppleSpatialCaptureProgress {
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

  final String operation;
  final AppleSpatialCaptureProgressStage stage;
  final String message;
  final double? progress;
  final int? etaSeconds;
  final int? elapsedSeconds;
  final String? operationId;
  final int? stepIndex;
  final int? stepTotal;
  final String? stepLabel;

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

class AppleSpatialCaptureError implements Exception {
  const AppleSpatialCaptureError({
    required this.code,
    required this.message,
    this.details,
  });

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'AppleSpatialCaptureError($code): $message';
}
